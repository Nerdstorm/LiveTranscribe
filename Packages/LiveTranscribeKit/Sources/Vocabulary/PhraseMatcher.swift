import Foundation

/// A phrase to look for, as word keys, and the canonical term it stands for.
struct PhrasePattern: Sendable {
    let keys: [String]
    /// Index of the canonical term in the owner's term list.
    let termIndex: Int
}

/// Where a pattern matched: the words it covers and the part of the text to replace.
struct PhraseMatch: Sendable, Equatable {
    let termIndex: Int
    let wordCount: Int
    /// From the first word's first letter to the last word's last letter, excluding a
    /// possessive "'s", so surrounding punctuation stays where it was.
    let range: Range<String.Index>
}

/// Finds whole-word phrase matches in tokenised text.
///
/// Shared by the replacer and the selector so both agree on what "occurs in the text" means:
/// whole words only, case-insensitive, punctuation around the phrase ignored, and nothing but
/// spaces or hyphens between its words. The last word may carry a possessive "'s".
struct PhraseMatcher: Sendable {
    /// Patterns indexed by their first word, each list ordered longest first and then in the
    /// order given, so the first match found at a position is the one to prefer.
    private let patternsByFirstKey: [String: [RankedPattern]]

    private struct RankedPattern: Sendable {
        let pattern: PhrasePattern
        let order: Int
    }

    /// Patterns without words (a variant of punctuation only) are ignored.
    init(patterns: [PhrasePattern]) {
        var byFirstKey: [String: [RankedPattern]] = [:]
        for (order, pattern) in patterns.enumerated() {
            guard let first = pattern.keys.first else { continue }
            byFirstKey[first, default: []].append(RankedPattern(pattern: pattern, order: order))
        }
        self.patternsByFirstKey = byFirstKey.mapValues { $0.sorted(by: Self.precedes) }
    }

    var isEmpty: Bool { patternsByFirstKey.isEmpty }

    /// The longest match starting at word `start`; among equally long ones, the earliest given.
    func longestMatch(at start: Int, in words: [TextWord], of text: String) -> PhraseMatch? {
        for candidate in candidates(for: words[start]) {
            if let match = match(candidate.pattern, at: start, in: words, of: text) {
                return match
            }
        }
        return nil
    }

    /// Every match starting at word `start`, longest first.
    func allMatches(at start: Int, in words: [TextWord], of text: String) -> [PhraseMatch] {
        candidates(for: words[start]).compactMap { match($0.pattern, at: start, in: words, of: text) }
    }

    private func candidates(for word: TextWord) -> [RankedPattern] {
        let exact = patternsByFirstKey[word.key] ?? []
        // "GitHub's" can only match a one-word pattern "github"; longer patterns need the
        // possessive on their last word, which is not their first.
        guard word.key.hasSuffix("'s"),
              let singles = patternsByFirstKey[String(word.key.dropLast(2))]?.filter({ $0.pattern.keys.count == 1 }),
              !singles.isEmpty
        else { return exact }
        return (exact + singles).sorted(by: Self.precedes)
    }

    private func match(_ pattern: PhrasePattern, at start: Int, in words: [TextWord], of text: String) -> PhraseMatch? {
        let count = pattern.keys.count
        guard start + count <= words.count else { return nil }
        var possessive = false
        for offset in 0..<count {
            let word = words[start + offset]
            if offset > 0, !word.joinsPrevious { return nil }
            if word.key == pattern.keys[offset] { continue }
            if offset == count - 1, WordTokenizer.isPossessive(word.key, of: pattern.keys[offset]) {
                possessive = true
                continue
            }
            return nil
        }
        let lastRange = words[start + count - 1].range
        // The key ends in "'s", so the word's last two characters are the apostrophe and the s.
        let end = possessive ? text.index(lastRange.upperBound, offsetBy: -2) : lastRange.upperBound
        return PhraseMatch(termIndex: pattern.termIndex, wordCount: count, range: words[start].range.lowerBound..<end)
    }

    private static func precedes(_ lhs: RankedPattern, _ rhs: RankedPattern) -> Bool {
        if lhs.pattern.keys.count != rhs.pattern.keys.count {
            return lhs.pattern.keys.count > rhs.pattern.keys.count
        }
        return lhs.order < rhs.order
    }
}
