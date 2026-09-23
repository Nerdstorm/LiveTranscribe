import Foundation
import Shared

/// Finds spoken snippet triggers in a raw transcript and swaps them for placeholder tokens, so the
/// language model never sees (and never "fixes") a URL, an address or a signature.
///
/// The dictation flow calls ``protect(_:)`` before cleanup, asks the model to keep the tokens
/// verbatim, and calls ``ProtectedText/restore(in:)`` on the model's output. A model that drops
/// or mangles a token is caught there instead of inserting half an expansion.
///
/// Matching:
/// - whole words only, after ``EditDistance/normalize(_:)``, so casing and punctuation do not
///   matter ("My calendar-link!" matches "my calendar link") but "link" never matches "linked";
/// - leftmost match first and, among matches starting at the same word, the longest, so
///   "my link to the calendar" wins over "my link";
/// - punctuation around the matched words that is not part of the trigger (a closing full stop,
///   an opening bracket) stays next to the placeholder: "Here's my calendar link." becomes
///   "Here's ⟦S1⟧.";
/// - a snippet that ``Snippet/validate(_:)`` would reject for its own content (a trigger with no
///   words, an empty expansion) or for repeating an earlier snippet's trigger is ignored.
public struct SnippetExpander: Sendable {
    /// Patterns keyed by their first word, longest first, so the first one that matches at a
    /// position is the longest.
    private let patternsByFirstWord: [String: [TriggerPattern]]

    /// Prepares the triggers once, so each dictation only pays for the matching itself. Snippets
    /// read from a hand-edited file may not have passed ``Snippet/validate(_:)``; the invalid ones
    /// are skipped here, by the same rules, rather than failing the whole dictation. The first of
    /// two snippets with the same trigger wins, as validation blames the later one.
    public init(snippets: [Snippet]) {
        var seenTriggers: Set<[String]> = []
        var patterns: [String: [TriggerPattern]] = [:]
        var ignored = 0
        for snippet in snippets {
            guard !snippet.expansion.isEmpty,
                  let pattern = TriggerPattern(snippet: snippet),
                  seenTriggers.insert(pattern.words).inserted
            else {
                ignored += 1
                continue
            }
            patterns[pattern.words[0], default: []].append(pattern)
        }
        // Ties need no order: two different triggers of the same length cannot both match at
        // the same position.
        self.patternsByFirstWord = patterns.mapValues { candidates in
            candidates.sorted { $0.words.count > $1.words.count }
        }
        if ignored > 0 {
            Log.snippets.notice("Ignoring \(ignored, privacy: .public) snippets with an empty trigger, an empty expansion or a repeated trigger")
        }
    }

    /// `text` with every trigger replaced by a placeholder token, numbered in order of
    /// appearance. Text without triggers comes back unchanged.
    public func protect(_ text: String) -> ProtectedText {
        guard !patternsByFirstWord.isEmpty else { return ProtectedText(unchanged: text) }
        let tokenized = TokenizedText(text)
        let matches = findMatches(in: tokenized)
        guard !matches.isEmpty else { return ProtectedText(unchanged: text) }

        var segments: [ProtectedText.Segment] = []
        var placeholders: [Placeholder] = []
        var cursor = text.startIndex
        for match in matches {
            let firstToken = tokenized.tokens[match.firstToken]
            let lastToken = tokenized.tokens[match.lastToken]
            let before = text[cursor..<firstToken.lowerBound] + match.pattern.keptLeading(of: text[firstToken])
            let after = match.pattern.keptTrailing(of: text[lastToken])

            let placeholder = Placeholder(
                token: Placeholder.token(number: placeholders.count + 1),
                trigger: match.pattern.snippet.trigger,
                expansion: match.pattern.snippet.expansion
            )
            segments.append(.literal(String(before)))
            segments.append(.placeholder(placeholders.count))
            segments.append(.literal(String(after)))
            placeholders.append(placeholder)
            cursor = lastToken.upperBound
        }
        segments.append(.literal(String(text[cursor...])))

        Log.snippets.debug("Protected \(placeholders.count, privacy: .public) snippet occurrences")
        return ProtectedText(segments: segments.filter { $0 != .literal("") }, placeholders: placeholders)
    }

    /// `text` with every trigger replaced by its expansion directly, for text that does not go
    /// through the language model (cleanup level None, or a fallback).
    public func expand(_ text: String) -> String {
        protect(text).expanded
    }

    // MARK: - Private

    private struct Match {
        let firstToken: Int
        let lastToken: Int
        let pattern: TriggerPattern
    }

    /// Leftmost, then longest, non-overlapping matches that cover whole tokens.
    private func findMatches(in text: TokenizedText) -> [Match] {
        let words = text.words
        var found: [Match] = []
        var position = 0
        while position < words.count {
            let word = words[position]
            guard word.startsToken,
                  let candidates = patternsByFirstWord[word.text],
                  let pattern = candidates.first(where: { Self.words(words, at: position, match: $0.words) })
            else {
                position += 1
                continue
            }
            let lastWord = words[position + pattern.words.count - 1]
            found.append(Match(firstToken: word.token, lastToken: lastWord.token, pattern: pattern))
            position += pattern.words.count
        }
        return found
    }

    /// Whether `pattern` matches the words starting at `position` and ends at the end of a token.
    private static func words(_ words: [TokenizedText.Word], at position: Int, match pattern: [String]) -> Bool {
        let end = position + pattern.count
        guard end <= words.count, words[end - 1].endsToken else { return false }
        return zip(pattern, words[position..<end]).allSatisfy { $0 == $1.text }
    }
}
