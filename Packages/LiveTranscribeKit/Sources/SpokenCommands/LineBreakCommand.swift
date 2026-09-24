import Foundation
import Shared

/// "New line" and "new paragraph": a line break, or a blank line, where the field takes several
/// lines, and a space where it does not, since a newline there could send a message or submit a
/// form.
///
/// The words stay words after a determiner or a possessive ("a new line of laptops", "Apple's
/// new line") or before "of" ("new line of code"). A break goes behind a placeholder, so the
/// model cannot drop it; ``SpokenCommands/tidyLineBreaks(_:)`` tidies the text around it once it
/// is put back. A space is written straight into the text: there is nothing for the model to
/// drop, and a placeholder it might drop would only cost the cleanup.
public struct LineBreakCommand: PhraseMatcher {
    private struct Phrase {
        let words: [String]
        let lines: Int
    }

    private static let phrases = [
        Phrase(words: ["new", "line"], lines: 1),
        Phrase(words: ["newline"], lines: 1),
        Phrase(words: ["new", "paragraph"], lines: 2),
    ]

    private let multiline: Bool

    public init(multiline: Bool) {
        self.multiline = multiline
    }

    public func matches(in text: TokenizedText) -> [PhraseMatch] {
        var found: [PhraseMatch] = []
        for position in text.words.indices where !PhraseGrammar.followsDeterminer(position, in: text) {
            for phrase in Self.phrases where PhraseGrammar.matches(phrase.words, at: position, in: text) {
                let end = position + phrase.words.count
                if end < text.words.count, text.words[end].text == "of" { continue }
                let replacement: PhraseMatch.Replacement = multiline
                    ? .placeholder(
                        trigger: phrase.words.joined(separator: " "),
                        expansion: String(repeating: "\n", count: phrase.lines),
                        role: .lineBreak
                    )
                    : .inline(InlineText(" ", joinsPrevious: true, joinsNext: true))
                found.append(PhraseMatch(
                    words: position..<end,
                    replacement: replacement,
                    keptTrailing: PhraseGrammar.trailingAfterClausePunctuation(text.token(ofWord: end - 1))
                ))
            }
        }
        return found
    }
}
