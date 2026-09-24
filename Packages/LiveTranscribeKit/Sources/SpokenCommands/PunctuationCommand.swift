import Foundation
import Shared

/// Punctuation dictated by name: "is it ready question mark" → "is it ready?", "he said open
/// quote I'll be late close quote" → "he said "I'll be late"".
///
/// Only names people rarely say for their own sake are commands, and none after a determiner
/// ("a question mark", "the full stop"), where the speaker is talking about the mark.
/// "Period", "colon" and "dash" stay words: they are common nouns ("the trial period"). A comma
/// or semicolon needs a word on each side. Quotes and brackets are commands only in pairs, an
/// opening one with a closing one later and words between, so a lone "end quote" or the idiom
/// "quote unquote" stays as said.
///
/// The mark is written into the text the model sees, not hidden behind a placeholder: the model
/// may still adjust it, as it does any punctuation.
public struct PunctuationCommand: PhraseMatcher {
    /// A mark that attaches to the word before it.
    public struct Mark: Sendable {
        public let names: [[String]]
        public let text: String
        /// Ends a sentence: the next word is capitalised.
        public let endsSentence: Bool

        public init(names: [[String]], text: String, endsSentence: Bool) {
            self.names = names
            self.text = text
            self.endsSentence = endsSentence
        }
    }

    /// An opening and a closing mark that enclose words.
    public struct Pair: Sendable {
        public let openingNames: [[String]]
        public let closingNames: [[String]]
        public let opening: String
        public let closing: String

        public init(openingNames: [[String]], closingNames: [[String]], opening: String, closing: String) {
            self.openingNames = openingNames
            self.closingNames = closingNames
            self.opening = opening
            self.closing = closing
        }
    }

    public static let standardMarks: [Mark] = [
        Mark(names: [["question", "mark"]], text: "?", endsSentence: true),
        Mark(names: [["exclamation", "mark"], ["exclamation", "point"]], text: "!", endsSentence: true),
        Mark(names: [["full", "stop"]], text: ".", endsSentence: true),
        Mark(names: [["comma"]], text: ",", endsSentence: false),
        Mark(names: [["semicolon"], ["semi", "colon"]], text: ";", endsSentence: false),
    ]

    /// Straight quotes, which suit code editors and terminals as well as prose.
    public static let standardPairs: [Pair] = [
        Pair(
            openingNames: [["open", "quote"], ["open", "quotes"], ["begin", "quote"], ["start", "quote"]],
            closingNames: [["close", "quote"], ["close", "quotes"], ["end", "quote"], ["end", "quotes"]],
            opening: "\"",
            closing: "\""
        ),
        Pair(openingNames: [["quote"]], closingNames: [["unquote"]], opening: "\"", closing: "\""),
        Pair(
            openingNames: [["open", "bracket"], ["open", "paren"], ["open", "parenthesis"], ["open", "parentheses"]],
            closingNames: [["close", "bracket"], ["close", "paren"], ["close", "parenthesis"], ["close", "parentheses"]],
            opening: "(",
            closing: ")"
        ),
    ]

    private let marks: [Mark]
    private let pairs: [Pair]

    public init(marks: [Mark] = standardMarks, pairs: [Pair] = standardPairs) {
        self.marks = marks
        self.pairs = pairs
    }

    public func matches(in text: TokenizedText) -> [PhraseMatch] {
        markMatches(in: text) + pairs.flatMap { pairMatches($0, in: text) }
    }

    // MARK: - Private

    private func markMatches(in text: TokenizedText) -> [PhraseMatch] {
        var found: [PhraseMatch] = []
        for position in text.words.indices.dropFirst() where !CommandGrammar.followsDeterminer(position, in: text) {
            for mark in marks {
                guard let name = Self.longestName(mark.names, at: position, in: text) else { continue }
                let end = position + name.count
                // A comma or semicolon between words only: at the end it would dangle.
                if !mark.endsSentence, end >= text.words.count { continue }
                found.append(PhraseMatch(
                    words: position..<end,
                    replacement: .inline(InlineText(
                        mark.text,
                        joinsPrevious: true,
                        replacesPrecedingPunctuation: true,
                        capitalizesNext: mark.endsSentence
                    )),
                    keptTrailing: CommandGrammar.trailingAfterClausePunctuation(text.token(ofWord: end - 1))
                ))
            }
        }
        return found
    }

    /// Openings paired with the next closing that has words between them; nested pairs of the
    /// same kind close innermost first.
    private func pairMatches(_ pair: Pair, in text: TokenizedText) -> [PhraseMatch] {
        var open: [Range<Int>] = []
        var found: [PhraseMatch] = []
        var position = 0
        while position < text.words.count {
            guard !CommandGrammar.followsDeterminer(position, in: text) else {
                position += 1
                continue
            }
            if let name = Self.longestName(pair.closingNames, at: position, in: text),
               let opening = open.last, opening.upperBound < position {
                open.removeLast()
                let closing = position..<(position + name.count)
                found.append(PhraseMatch(
                    words: opening,
                    replacement: .inline(InlineText(pair.opening, joinsNext: true))
                ))
                found.append(PhraseMatch(
                    words: closing,
                    replacement: .inline(InlineText(pair.closing, joinsPrevious: true)),
                    keptTrailing: String(TokenEdges.trailing(of: text.token(ofWord: closing.upperBound - 1)))
                ))
                position = closing.upperBound
            } else if let name = Self.longestName(pair.openingNames, at: position, in: text),
                      !Self.isPartOfLongerName(position, in: text) {
                open.append(position..<(position + name.count))
                position += name.count
            } else {
                position += 1
            }
        }
        return found
    }

    private static func longestName(_ names: [[String]], at position: Int, in text: TokenizedText) -> [String]? {
        names
            .filter { CommandGrammar.matches($0, at: position, in: text) }
            .max { $0.count < $1.count }
    }

    /// "quote" right after "open", "close", "end", "start" or "begin" belongs to that two-word
    /// name, never to the "quote … unquote" pair.
    private static func isPartOfLongerName(_ position: Int, in text: TokenizedText) -> Bool {
        guard position > 0, text.words[position].text == "quote" else { return false }
        return ["open", "close", "end", "start", "begin"].contains(text.words[position - 1].text)
    }
}
