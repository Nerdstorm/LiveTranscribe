import Foundation

/// Text split the way phrase matching sees it: whitespace-delimited tokens, and the normalised
/// words each token contributes.
///
/// A token usually contributes one word, but a hyphenated token ("calendar-link") contributes
/// several and a lone dash or ellipsis none, because ``EditDistance/normalize(_:)`` splits on
/// hyphens and drops punctuation. Matches must start at a token's first word and end at a
/// token's last word, so only whole tokens are ever replaced.
public struct TokenizedText: Sendable {
    public struct Word: Sendable, Equatable {
        /// The word as ``EditDistance/normalize(_:)`` leaves it: lowercased, without punctuation.
        public let text: String
        /// Index into ``TokenizedText/tokens`` of the token the word is in.
        public let token: Int
        public let startsToken: Bool
        public let endsToken: Bool
    }

    /// The text that was split.
    public let text: String
    /// Character ranges of the whitespace-delimited tokens, in order.
    public let tokens: [Range<String.Index>]
    public let words: [Word]

    public init(_ text: String) {
        var tokens: [Range<String.Index>] = []
        var tokenStart: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            if text[index].isWhitespace {
                if let start = tokenStart {
                    tokens.append(start..<index)
                    tokenStart = nil
                }
            } else if tokenStart == nil {
                tokenStart = index
            }
            index = text.index(after: index)
        }
        if let start = tokenStart {
            tokens.append(start..<text.endIndex)
        }

        var words: [Word] = []
        for (tokenIndex, range) in tokens.enumerated() {
            let tokenWords = EditDistance.words(in: EditDistance.normalize(String(text[range])))
            for (position, word) in tokenWords.enumerated() {
                words.append(Word(
                    text: word,
                    token: tokenIndex,
                    startsToken: position == 0,
                    endsToken: position == tokenWords.count - 1
                ))
            }
        }
        self.text = text
        self.tokens = tokens
        self.words = words
    }

    /// The characters of token `index`.
    public func token(_ index: Int) -> Substring {
        text[tokens[index]]
    }

    /// The characters of the token that word `index` is in.
    public func token(ofWord index: Int) -> Substring {
        token(words[index].token)
    }

    /// The normalised words in `range`, for comparing with a phrase.
    public func words(in range: Range<Int>) -> [String] {
        words[range].map(\.text)
    }

    /// Whether the words in `range` are whole tokens: the first starts a token and the last ends one.
    public func coversWholeTokens(_ range: Range<Int>) -> Bool {
        guard !range.isEmpty, range.lowerBound >= 0, range.upperBound <= words.count else { return false }
        return words[range.lowerBound].startsToken && words[range.upperBound - 1].endsToken
    }
}

/// The punctuation around a token's letters and digits.
public enum TokenEdges {
    /// Characters before the first letter or digit. Empty for a token with no letters or digits,
    /// so its characters are never counted twice as both leading and trailing.
    public static func leading(of token: Substring) -> Substring {
        guard let first = token.firstIndex(where: isWordCharacter) else { return token.prefix(0) }
        return token[..<first]
    }

    /// Characters after the last letter or digit; empty for a token with no letters or digits.
    public static func trailing(of token: Substring) -> Substring {
        guard let last = token.lastIndex(where: isWordCharacter) else { return token.suffix(0) }
        return token[token.index(after: last)...]
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }
}
