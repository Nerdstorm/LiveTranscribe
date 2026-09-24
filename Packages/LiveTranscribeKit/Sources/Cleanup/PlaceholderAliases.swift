import Foundation
import Shared

/// Placeholder tokens as the cleanup model sees them: short words ("S1", "S2") instead of the
/// bracketed tokens (`⟦S1⟧`) the rest of dictation uses.
///
/// The model treats the brackets as noise. In the prompt probe (`PromptProbeTests`) it stripped
/// or dropped 17 of 23 bracketed tokens, and kept 21 of 23 of the same tokens written as words.
/// So the executor writes each token as its alias before the model runs, and puts the tokens
/// back in the output before the guard reviews it. The guard, and everything after it, sees only
/// tokens.
///
/// An alias must not already be a word in the text, or that word would become a token on the
/// way back, so the letter changes until none is: "the S1 form" gets T1, T2, and so on.
struct PlaceholderAliases: Sendable {
    private static let letters: [Character] = ["S", "T", "P", "Q", "Z"]

    /// Each token and the word the model sees for it, in the order the tokens were given.
    let pairs: [(token: String, alias: String)]

    /// - Parameters:
    ///   - tokens: The placeholder tokens in `text`.
    ///   - text: The text the model will see.
    init(tokens: [String], text: String) {
        guard !tokens.isEmpty else {
            pairs = []
            return
        }
        let visible = tokens.reduce(text) { $0.replacingOccurrences(of: $1, with: " ") }
        let words = Set(visible.split { !$0.isLetter && !$0.isNumber }.map { $0.uppercased() })
        let letter = Self.letters.first { letter in
            !words.contains { $0.count > 1 && $0.first == letter && $0.dropFirst().allSatisfy(\.isNumber) }
        }
        guard let letter else {
            // Words like S1, T1, P1, Q1 and Z1 all in one text: the model sees the tokens.
            Log.cleanup.notice("No free alias letter for placeholders; the model sees the tokens")
            pairs = tokens.map { ($0, $0) }
            return
        }
        pairs = tokens.enumerated().map { ($1, "\(letter)\($0 + 1)") }
    }

    /// The words the model sees, in the order of the tokens.
    var aliases: [String] {
        pairs.map(\.alias)
    }

    /// `text` with each token replaced by its alias.
    func aliased(_ text: String) -> String {
        pairs.reduce(text) { $0.replacingOccurrences(of: $1.token, with: $1.alias) }
    }

    /// `output` with each alias that appears exactly once, as a whole word in any case, replaced
    /// by its token. An alias the model dropped or repeated is left as it is, so the guard, which
    /// counts tokens, rejects the output.
    func restored(_ output: String) -> String {
        var restored = output
        for pair in pairs where pair.alias != pair.token {
            let ranges = Self.wholeWordRanges(of: pair.alias, in: restored)
            guard ranges.count == 1, let range = ranges.first else { continue }
            restored.replaceSubrange(range, with: pair.token)
        }
        return restored
    }

    // MARK: - Private

    /// Where `word` appears in `text` with no letter, digit or token bracket either side,
    /// ignoring case.
    private static func wholeWordRanges(of word: String, in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var searchStart = text.startIndex
        while let range = text.range(of: word, options: .caseInsensitive, range: searchStart..<text.endIndex) {
            let before = range.lowerBound > text.startIndex ? text[text.index(before: range.lowerBound)] : nil
            let after = range.upperBound < text.endIndex ? text[range.upperBound] : nil
            if !joinsWord(before), !joinsWord(after) {
                ranges.append(range)
            }
            searchStart = range.upperBound
        }
        return ranges
    }

    private static func joinsWord(_ character: Character?) -> Bool {
        guard let character else { return false }
        return character.isLetter || character.isNumber
            || character == PlaceholderToken.opening || character == PlaceholderToken.closing
    }
}
