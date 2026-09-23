import Foundation
import Shared

/// One word of a text, located in the original string so a match can be replaced in place.
struct TextWord: Sendable, Equatable {
    /// The word without the punctuation around it: from its first letter or digit to its last.
    /// Punctuation inside the word stays ("don't", "Node.js", "1,000").
    let range: Range<String.Index>
    /// The word as matching sees it: lowercased, with typographic apostrophes made plain.
    let key: String
    /// Whether only spaces and hyphens separate this word from the one before it. A comma, a
    /// full stop or a line break in between means the two words were not said as one phrase.
    let joinsPrevious: Bool
}

/// Splits text into words for vocabulary matching, keeping every word's position.
///
/// Matching compares words rather than characters so that "git hub" never matches inside
/// "git hubs", and punctuation around a word ("storm.", "(nerd") neither blocks a match nor is
/// lost when the word is replaced. Replacer, selector and validation all share this one
/// definition of a word, so a variant the store accepts is a variant the replacer can find.
///
/// Snippet placeholders (``PlaceholderToken``, "⟦S1⟧") are already in the text when the
/// replacer runs. They yield no words, so no vocabulary phrase can alter one and break the
/// snippet's expansion.
enum WordTokenizer {
    /// The brackets around a snippet placeholder. Taken from ``PlaceholderToken`` so that a
    /// change to the token format cannot leave placeholders unprotected here.
    static let placeholderOpening = PlaceholderToken.opening
    static let placeholderClosing = PlaceholderToken.closing

    /// Characters that separate words without breaking a phrase: spaces, tabs and hyphens, so
    /// "nerd-storm" matches the variant "nerd storm". Line breaks are deliberately not included.
    static func isPhraseSeparator(_ character: Character) -> Bool {
        (character.isWhitespace && !character.isNewline)
            || character == "-" || character == "\u{2010}" || character == "\u{2011}"
    }

    /// Letters and digits start and end a word; anything else at the edges is punctuation.
    static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    /// Every word of `text`, in order.
    static func words(in text: String) -> [TextWord] {
        var words: [TextWord] = []
        var gapIsPlain = true
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if isPhraseSeparator(character) {
                index = text.index(after: index)
                continue
            }
            if character.isNewline {
                gapIsPlain = false
                index = text.index(after: index)
                continue
            }
            if character == placeholderOpening, let closing = text[index...].firstIndex(of: placeholderClosing) {
                gapIsPlain = false
                index = text.index(after: closing)
                continue
            }
            // A chunk runs to the next separator, line break or placeholder.
            var chunkEnd = text.index(after: index)
            while chunkEnd < text.endIndex, !endsChunk(text[chunkEnd]) {
                chunkEnd = text.index(after: chunkEnd)
            }
            let chunk = text[index..<chunkEnd]
            if let first = chunk.firstIndex(where: isWordCharacter),
               let last = chunk.lastIndex(where: isWordCharacter) {
                let range = first..<text.index(after: last)
                words.append(TextWord(range: range, key: key(for: text[range]), joinsPrevious: gapIsPlain && first == index))
                gapIsPlain = range.upperBound == chunkEnd
            } else {
                // A chunk of punctuation only ("…", "—", a lone comma).
                gapIsPlain = false
            }
            index = chunkEnd
        }
        return words
    }

    private static func endsChunk(_ character: Character) -> Bool {
        isPhraseSeparator(character) || character.isNewline || character == placeholderOpening
    }

    /// The keys of a phrase's words, the form in which variants and terms are compared.
    static func keys(of phrase: String) -> [String] {
        words(in: phrase).map(\.key)
    }

    /// One string per phrase for de-duplication and conflict checks: "Nerd-storm." and
    /// "nerd storm" are the same phrase to the matcher, so they share a key.
    static func phraseKey(_ phrase: String) -> String {
        keys(of: phrase).joined(separator: " ")
    }

    static func key(for word: Substring) -> String {
        word.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
    }

    /// Whether `word` (a matched word's key) is `key` followed by a possessive "'s", so
    /// "GitHub's" is recognised as "GitHub" and keeps its "'s".
    static func isPossessive(_ word: String, of key: String) -> Bool {
        word == key + "'s"
    }
}
