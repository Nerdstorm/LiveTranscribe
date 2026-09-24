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
            lines[index] = SentenceCase.capitalizingFirstWord(line)
        }
        return lines
            .joined(separator: "\n")
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
    }

    private static let clauseEnders = PhraseGrammar.clauseEnders
}
