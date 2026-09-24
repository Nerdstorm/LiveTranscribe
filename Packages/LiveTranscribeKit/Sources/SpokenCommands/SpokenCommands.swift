import Foundation
import Shared

/// Phrases dictation treats as commands rather than words: emoji ("emoji fireworks" → 🎆),
/// dictated punctuation ("question mark" → ?), line breaks ("new paragraph") and email and web
/// addresses ("john dot smith at example dot com").
///
/// Like snippets, they apply at every cleanup level and only in dictation, before the language
/// model runs: an emoji or an address goes behind a placeholder the model cannot change, and a
/// line break behind one it cannot drop. Each kind is a ``PhraseMatcher``; a new kind of command
/// is one more matcher in ``matchers(multiline:)``.
public enum SpokenCommands {
    /// The commands for one dictation, in priority order for matches that tie.
    ///
    /// - Parameter multiline: The field takes several lines. Elsewhere a spoken line break
    ///   becomes a space, since a newline could send a chat message or submit a form.
    public static func matchers(multiline: Bool) -> [any PhraseMatcher] {
        [
            EmojiCommand(),
            AddressCommand(),
            PunctuationCommand(),
            LineBreakCommand(multiline: multiline),
        ]
    }

    /// Tidies text whose line-break placeholders were just put back (see
    /// ``Placeholder/Role/lineBreak``).
    ///
    /// The model sees a break as a token between words, so it punctuates around it as it likes:
    /// "Hi John ⟦S1⟧, thanks." Here the space around each break goes, punctuation the model put
    /// just after a break moves back to the end of the line before it, the first word after a
    /// break is capitalised, runs of spaces become one, and there is never more than one blank
    /// line in a row.
    public static func tidyLineBreaks(_ text: String) -> String {
        let singleSpaced = text.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
        var lines = singleSpaced
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        for index in lines.indices.dropFirst() {
            var line = lines[index]
            let punctuation = line.prefix { clauseEnders.contains($0) || $0 == " " }
            if !punctuation.isEmpty {
                line = String(line.dropFirst(punctuation.count))
                let moved = punctuation.filter { $0 != " " }
                if let previous = lines[..<index].lastIndex(where: { !$0.isEmpty }),
                   let end = lines[previous].last, !clauseEnders.contains(end) {
                    lines[previous] += moved
                }
            }
            if let first = line.first, first.isLowercase {
                line = first.uppercased() + line.dropFirst()
            }
            lines[index] = line
        }
        return lines
            .joined(separator: "\n")
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
    }

    static let clauseEnders: Set<Character> = [",", ";", ":", ".", "!", "?"]
}

/// Word checks the commands share.
enum CommandGrammar {
    /// Words after which a command's words are a noun phrase, as in "a question mark", "the new
    /// line of laptops" or "our new line": the speaker is talking about the thing, not asking for
    /// it.
    static let determiners: Set<String> = [
        "a", "an", "the", "this", "that", "these", "those", "each", "every", "any", "no", "one",
        "my", "your", "his", "her", "its", "our", "their", "another", "which", "what", "whose", "same", "some",
    ]

    /// Whether the word before `position` is a determiner or a possessive ("Apple's") in the same
    /// clause.
    static func followsDeterminer(_ position: Int, in text: TokenizedText) -> Bool {
        guard position > 0 else { return false }
        let previous = text.words[position - 1]
        guard previous.endsToken, !endsClause(text.token(previous.token)) else { return false }
        return determiners.contains(previous.text) || previous.text.hasSuffix("'s")
    }

    /// Whether `token` ends with punctuation that ends a clause.
    static func endsClause(_ token: Substring) -> Bool {
        TokenEdges.trailing(of: token).contains { SpokenCommands.clauseEnders.contains($0) }
    }

    /// The token's trailing punctuation after any clause punctuation at its start: what stays in
    /// the text when a command replaces the punctuation the transcript had ("mark.\"" keeps the
    /// closing quote).
    static func trailingAfterClausePunctuation(_ token: Substring) -> String {
        String(TokenEdges.trailing(of: token).drop { SpokenCommands.clauseEnders.contains($0) })
    }

    /// Whether the words at `position` are `phrase` and cover whole tokens.
    static func matches(_ phrase: [String], at position: Int, in text: TokenizedText) -> Bool {
        let range = position..<(position + phrase.count)
        guard range.upperBound <= text.words.count, text.coversWholeTokens(range) else { return false }
        return text.words(in: range) == phrase
    }

    /// Whether no token inside `range` other than the last ends a clause, so the words run on in
    /// one phrase.
    static func runsOn(_ range: Range<Int>, in text: TokenizedText) -> Bool {
        let lastToken = text.words[range.upperBound - 1].token
        return range.allSatisfy { index in
            let word = text.words[index]
            return word.token == lastToken || !word.endsToken || !endsClause(text.token(word.token))
        }
    }
}
