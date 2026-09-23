import Foundation
import Shared

/// Text split the way trigger matching sees it: whitespace-delimited tokens, and the normalised
/// words each token contributes.
///
/// A token usually contributes one word, but a hyphenated token ("calendar-link") contributes
/// several and a lone dash or ellipsis none, because ``EditDistance/normalize(_:)`` splits on
/// hyphens and drops punctuation. Matches must start at a token's first word and end at a
/// token's last word, so only whole tokens are ever replaced.
struct TokenizedText {
    struct Word {
        let text: String
        let token: Int
        let startsToken: Bool
        let endsToken: Bool
    }

    /// Character ranges of the whitespace-delimited tokens, in order.
    let tokens: [Range<String.Index>]
    let words: [Word]

    init(_ text: String) {
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
        self.tokens = tokens
        self.words = words
    }
}

/// A snippet's trigger prepared for matching.
struct TriggerPattern: Sendable {
    let words: [String]
    /// Punctuation before the trigger's first word that belongs to the trigger ("@" in "@home").
    let leadingPunctuation: String
    /// Punctuation after the trigger's last word that belongs to the trigger ("++" in "c++").
    let trailingPunctuation: String
    let snippet: Snippet

    /// `nil` when the trigger has no words, which could never match.
    init?(snippet: Snippet) {
        let words = snippet.triggerWords
        guard !words.isEmpty else { return nil }
        let wordTokens = snippet.trigger
            .split(whereSeparator: \.isWhitespace)
            .filter { !EditDistance.normalize(String($0)).isEmpty }
        self.words = words
        self.leadingPunctuation = wordTokens.first.map { String(TokenEdges.leading(of: $0)) } ?? ""
        self.trailingPunctuation = wordTokens.last.map { String(TokenEdges.trailing(of: $0)) } ?? ""
        self.snippet = snippet
    }

    /// The part of a matched token's leading punctuation that stays in the text, next to the
    /// placeholder: an opening bracket or quote, but not punctuation the trigger itself starts with.
    func keptLeading(of token: Substring) -> Substring {
        let leading = TokenEdges.leading(of: token)
        guard !leadingPunctuation.isEmpty, leading.hasSuffix(leadingPunctuation) else { return leading }
        return leading.dropLast(leadingPunctuation.count)
    }

    /// The part of a matched token's trailing punctuation that stays in the text: a full stop or
    /// comma, but not punctuation the trigger itself ends with.
    func keptTrailing(of token: Substring) -> Substring {
        let trailing = TokenEdges.trailing(of: token)
        guard !trailingPunctuation.isEmpty, trailing.hasPrefix(trailingPunctuation) else { return trailing }
        return trailing.dropFirst(trailingPunctuation.count)
    }
}

/// The punctuation around a token's letters and digits.
enum TokenEdges {
    /// Characters before the first letter or digit. Empty for a token with no letters or digits,
    /// so its characters are never counted twice as both leading and trailing.
    static func leading(of token: Substring) -> Substring {
        guard let first = token.firstIndex(where: isWordCharacter) else { return token.prefix(0) }
        return token[..<first]
    }

    /// Characters after the last letter or digit; empty for a token with no letters or digits.
    static func trailing(of token: Substring) -> Substring {
        guard let last = token.lastIndex(where: isWordCharacter) else { return token.suffix(0) }
        return token[token.index(after: last)...]
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }
}
