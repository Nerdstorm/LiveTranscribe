import Foundation

/// The text as ``NumberStyle`` reads it: words, and what comes between them.
extension NumberStyle {
    /// One word of the text: a whole token, or one part of a hyphenated token ("twenty-one").
    struct Word {
        /// Lowercased, without the punctuation around it.
        let text: String
        let range: Range<String.Index>
        let startsToken: Bool
        /// The token mixes number words with others, "twenty-five-year-old": its number words end
        /// any number they continue.
        let inMixedToken: Bool
        /// The punctuation after the word when it ends its token, such as the comma of "thousand,".
        let trailing: Substring
        /// A line break, punctuation on its own or the next token's opening punctuation comes after
        /// the word, or the text ends.
        var separatedFromNext = false

        /// Nothing but a space comes between this word and the next.
        var runsOn: Bool { trailing.isEmpty && !separatedFromNext }
    }

    /// The words of `text`, split at whitespace and hyphens, with what comes between them.
    static func words(in text: String) -> [Word] {
        var tokens: [(range: Range<String.Index>, afterLineBreak: Bool)] = []
        var start: String.Index?
        var lineBreak = false
        var index = text.startIndex
        while index < text.endIndex {
            if text[index].isWhitespace {
                if let begin = start {
                    tokens.append((begin..<index, lineBreak))
                    start = nil
                    lineBreak = false
                }
                if text[index].isNewline { lineBreak = true }
            } else if start == nil {
                start = index
            }
            index = text.index(after: index)
        }
        if let begin = start { tokens.append((begin..<text.endIndex, lineBreak)) }

        var words: [Word] = []
        for token in tokens {
            let characters = text[token.range]
            guard let first = characters.firstIndex(where: isWordCharacter),
                  let last = characters.lastIndex(where: isWordCharacter)
            else {
                // Punctuation on its own, such as a dash, ends a number.
                if !words.isEmpty { words[words.count - 1].separatedFromNext = true }
                continue
            }
            if (token.afterLineBreak || first != characters.startIndex), !words.isEmpty {
                words[words.count - 1].separatedFromNext = true
            }
            let core = first..<characters.index(after: last)
            let parts = hyphenatedParts(of: core, in: text)
            let texts = parts.map { text[$0].lowercased() }
            let mixed = texts.contains(where: NumberWords.isNumberWord) && !texts.allSatisfy(NumberWords.isNumberWord)
            for (offset, part) in parts.enumerated() {
                let endsToken = offset == parts.count - 1
                words.append(Word(
                    text: texts[offset],
                    range: part,
                    startsToken: offset == 0,
                    inMixedToken: mixed,
                    trailing: endsToken ? characters[core.upperBound...] : characters[core.upperBound..<core.upperBound]
                ))
            }
        }
        if !words.isEmpty { words[words.count - 1].separatedFromNext = true }
        return words
    }

    /// The parts of a hyphenated word ("twenty-one"), or the whole word when a part is empty.
    private static func hyphenatedParts(of core: Range<String.Index>, in text: String) -> [Range<String.Index>] {
        var parts: [Range<String.Index>] = []
        var partStart = core.lowerBound
        var index = core.lowerBound
        while index < core.upperBound {
            if text[index] == "-" {
                parts.append(partStart..<index)
                partStart = text.index(after: index)
            }
            index = text.index(after: index)
        }
        parts.append(partStart..<core.upperBound)
        return parts.contains(where: \.isEmpty) ? [core] : parts
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    /// The word before word `index` with only a space between, or `nil`.
    static func text(before index: Int, in words: [Word]) -> String? {
        index > 0 && words[index - 1].runsOn ? words[index - 1].text : nil
    }

    /// The word after word `index` with only a space between, or `nil`.
    static func text(after index: Int, in words: [Word]) -> String? {
        index + 1 < words.count && words[index].runsOn ? words[index + 1].text : nil
    }
}
