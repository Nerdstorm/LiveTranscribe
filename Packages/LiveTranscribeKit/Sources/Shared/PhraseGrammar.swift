import Foundation

/// Word checks that spoken commands share: whether a phrase is being used as a command or
/// talked about, and how it sits among the punctuation around it.
public enum PhraseGrammar {
    /// Punctuation that ends a clause.
    public static let clauseEnders: Set<Character> = [",", ";", ":", ".", "!", "?"]

    /// Words after which a command's words are a noun phrase, as in "a question mark", "the new
    /// line of laptops" or "our new line": the speaker is talking about the thing, not asking for
    /// it.
    public static let determiners: Set<String> = [
        "a", "an", "the", "this", "that", "these", "those", "each", "every", "any", "no", "one",
        "my", "your", "his", "her", "its", "our", "their", "another", "which", "what", "whose", "same", "some",
    ]

    /// Whether the word before `position` is a determiner or a possessive ("Apple's") in the same
    /// clause.
    public static func followsDeterminer(_ position: Int, in text: TokenizedText) -> Bool {
        guard position > 0 else { return false }
        let previous = text.words[position - 1]
        guard previous.endsToken, !endsClause(text.token(previous.token)) else { return false }
        return determiners.contains(previous.text) || previous.text.hasSuffix("'s")
    }

    /// Whether `token` ends with punctuation that ends a clause.
    public static func endsClause(_ token: Substring) -> Bool {
        TokenEdges.trailing(of: token).contains { clauseEnders.contains($0) }
    }

    /// The token's trailing punctuation after any clause punctuation at its start: what stays in
    /// the text when a command replaces the punctuation the transcript had ("mark.\"" keeps the
    /// closing quote).
    public static func trailingAfterClausePunctuation(_ token: Substring) -> String {
        String(TokenEdges.trailing(of: token).drop { clauseEnders.contains($0) })
    }

    /// Whether the words at `position` are `phrase` and cover whole tokens.
    public static func matches(_ phrase: [String], at position: Int, in text: TokenizedText) -> Bool {
        let range = position..<(position + phrase.count)
        guard range.upperBound <= text.words.count, text.coversWholeTokens(range) else { return false }
        return text.words(in: range) == phrase
    }

    /// Whether no token inside `range` other than the last ends a clause, so the words run on in
    /// one phrase.
    public static func runsOn(_ range: Range<Int>, in text: TokenizedText) -> Bool {
        let lastToken = text.words[range.upperBound - 1].token
        return range.allSatisfy { index in
            let word = text.words[index]
            return word.token == lastToken || !word.endsToken || !endsClause(text.token(word.token))
        }
    }
}
