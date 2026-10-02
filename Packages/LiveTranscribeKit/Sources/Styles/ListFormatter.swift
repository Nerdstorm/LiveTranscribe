import Foundation
import Shared

/// Turns a spoken enumeration into a numbered list: "We need three things: first, milk; second,
/// eggs; and third, bread." becomes "We need three things:\n1. Milk\n2. Eggs\n3. Bread".
///
/// Deterministic, so it never changes words: it only moves them onto lines. A list needs at
/// least two items numbered in order from one, each number starting a clause (at the start of
/// the text, after punctuation, or after "and" / "then"); "finally" or "lastly" may end it. The
/// numbers are spoken ordinals ("first", "second", … or "firstly", …), cardinals ("one",
/// "two", … or 1, 2, …) or cardinals after "number", "item" or "step" ("number two"), and a list
/// may switch between them: "One, … Number two, …", "First, … Two, …". A cardinal said alone
/// counts only when "is", a comma, a colon or a full stop follows it, as in "One is the launch.
/// Two, the marketing.", so "One of them left" and "Two people came" stay as said.
///
/// A number said again before the list's next one moves the marker to it when it starts a
/// sentence and the first did not, so numbers inside an item stay in it: "One, when we fix one, and
/// two, then does it pass? Number two, …". A one said again also starts the list again when both
/// start sentences, or neither does: "One is enough. One is the launch. Two, …". The last item
/// runs to the end of its sentence, and any text after that starts a new paragraph. The lead-in
/// and items are punctuated by ``ListStyle``.
///
/// Words that only introduce an item belong to its number: "First of all, …", "First is …",
/// "One is …", "Second thing is …", "Third one's …". The "is" stays in the item after a comma
/// ("First, is it ready?") or in a question ("First is it ready?").
public struct ListFormatter: Sendable {
    static let ordinals: [String: Int] = [
        "first": 1, "firstly": 1, "second": 2, "secondly": 2, "third": 3, "thirdly": 3,
        "fourth": 4, "fourthly": 4, "fifth": 5, "fifthly": 5, "sixth": 6, "seventh": 7,
        "eighth": 8, "ninth": 9, "tenth": 10,
    ]
    private static let cardinals: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10, "1": 1, "2": 2, "3": 3, "4": 4, "5": 5, "6": 6, "7": 7, "8": 8, "9": 9, "10": 10,
    ]
    /// Marks after a cardinal that make it a list number: "Two, …", "Three: …", "Four. …".
    private static let cardinalEnders: Set<Character> = [",", ":", "."]
    private static let closers: Set<String> = ["finally", "lastly"]
    private static let connectors: Set<String> = ["and", "then"]
    /// "First is …", "Second was …".
    private static let copulas: Set<String> = ["is", "was"]
    /// "First thing is …", "Second one's …".
    private static let markerNouns: Set<String> = ["one", "thing", "item", "task", "step"]
    private static let clauseEnders = PhraseGrammar.clauseEnders
    private static let sentenceEnders: Set<Character> = [".", "!", "?"]

    private let style: ListStyle

    public init(style: ListStyle = ListStyle()) {
        self.style = style
    }

    /// `text` as a numbered list, or `nil` when it is not a spoken enumeration.
    public func formatted(_ text: String) -> String? {
        lines(for: text)?.joined(separator: "\n")
    }

    /// The list's lines: the lead-in if there is one, the items, and any text after the list.
    func lines(for text: String) -> [String]? {
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let markers = markers(in: tokens), markers.count >= 2 else { return nil }

        var items: [String] = []
        for (index, marker) in markers.enumerated() {
            let start = Self.itemStart(after: Self.numberIndex(ofMarkerAt: marker, in: tokens), in: tokens)
            var end: Int
            if index + 1 < markers.count {
                end = markers[index + 1]
                while end > start, Self.connectors.contains(Self.core(tokens[end - 1])) {
                    end -= 1
                }
            } else {
                end = tokens[start...].firstIndex(where: Self.endsSentence).map { $0 + 1 } ?? tokens.count
            }
            guard start < end else { return nil }
            items.append(tokens[start..<end].joined(separator: " "))
        }
        let styled = style.items(items)
        guard !styled.contains(where: \.isEmpty) else { return nil }

        var lines: [String] = []
        if let leadIn = style.leadIn(tokens[..<markers[0]].joined(separator: " ")) {
            lines.append(leadIn)
        }
        lines += styled.enumerated().map { "\($0.offset + 1). \($0.element)" }
        let lastNumber = Self.numberIndex(ofMarkerAt: markers.last!, in: tokens)
        let lastItemEnd = tokens[(lastNumber + 1)...].firstIndex(where: Self.endsSentence).map { $0 + 1 } ?? tokens.count
        if lastItemEnd < tokens.count {
            lines += ["", tokens[lastItemEnd...].joined(separator: " ")]
        }
        return lines
    }

    /// Token indices of the list's numbers, where each starts: the first run of at least two
    /// numbers in order from one, each starting a clause, with "finally" or "lastly" after the
    /// second or later; `nil` when there is none. A number said again moves its marker as the
    /// type's rules say.
    private func markers(in tokens: [String]) -> [Int]? {
        var markers: [Int] = []
        for index in tokens.indices where Self.startsClause(index, in: tokens) {
            let number = Self.number(at: index, in: tokens)
            if number == markers.count + 1 {
                markers.append(index)
            } else if let last = markers.last, number == markers.count,
                      Self.takesOver(index, from: last, saying: markers.count, in: tokens) {
                markers[markers.count - 1] = index
            } else if markers.count >= 2, Self.closers.contains(Self.core(tokens[index])) {
                markers.append(index)
                break
            }
        }
        return markers.count >= 2 ? markers : nil
    }

    /// Whether the marker at `index`, which says `number` again, takes over from the run's last
    /// marker at `last`: when it starts a sentence and `last` does not, or, for a one, when both
    /// or neither do.
    private static func takesOver(_ index: Int, from last: Int, saying number: Int, in tokens: [String]) -> Bool {
        let opensSentence = startsSentence(index, in: tokens)
        let lastOpensSentence = startsSentence(last, in: tokens)
        return number == 1 ? opensSentence || !lastOpensSentence : opensSentence && !lastOpensSentence
    }

    /// The number the marker starting at `index` gives its item, or `nil`: an ordinal, a cardinal
    /// said alone, or a cardinal after "number", "item" or "step".
    private static func number(at index: Int, in tokens: [String]) -> Int? {
        ordinal(at: index, in: tokens) ?? cardinal(at: index, in: tokens) ?? keyworded(at: index, in: tokens)
    }

    /// The token index of the number in the marker starting at `index`: the next one after
    /// "number", "item" or "step", or `index` itself.
    private static func numberIndex(ofMarkerAt index: Int, in tokens: [String]) -> Int {
        keyworded(at: index, in: tokens) == nil ? index : index + 1
    }

    /// The number the ordinal at `index` gives its item ("second" → 2), or `nil`.
    private static func ordinal(at index: Int, in tokens: [String]) -> Int? {
        ordinals[core(tokens[index])]
    }

    /// The number a cardinal after "number", "item" or "step" at `index` gives its item ("number
    /// two" → 2), or `nil`, also when no words follow it.
    private static func keyworded(at index: Int, in tokens: [String]) -> Int? {
        guard index + 2 < tokens.count, tokens[index].last?.isPunctuation != true,
              ListMarkerCommand.numberedKeywords.contains(core(tokens[index]))
        else { return nil }
        return cardinals[core(tokens[index + 1])]
    }

    /// The number the cardinal at `index` gives its item, or `nil` when it is not followed by
    /// "is", a comma, a colon or a full stop, or ends the text.
    private static func cardinal(at index: Int, in tokens: [String]) -> Int? {
        guard let number = cardinals[core(tokens[index])], index + 1 < tokens.count else { return nil }
        if let last = tokens[index].last, cardinalEnders.contains(last) { return number }
        return copulas.contains(core(tokens[index + 1])) ? number : nil
    }

    /// Where the item introduced by the number at token `marker` starts: after the words that
    /// belong to the marker (see the type's rules).
    private static func itemStart(after marker: Int, in tokens: [String]) -> Int {
        let next = marker + 1
        if next + 1 < tokens.count, core(tokens[marker]) == "first", core(tokens[next]) == "of", core(tokens[next + 1]) == "all" {
            return next + 2
        }
        guard next < tokens.count, tokens[marker].last?.isPunctuation != true, !asksQuestion(from: next, in: tokens)
        else { return next }
        let word = core(tokens[next])
        if copulas.contains(word) || (word.hasSuffix("'s") && markerNouns.contains(String(word.dropLast(2)))) {
            return next + 1
        }
        if markerNouns.contains(word), tokens[next].last?.isPunctuation != true, next + 1 < tokens.count,
           copulas.contains(core(tokens[next + 1])) {
            return next + 2
        }
        return next
    }

    /// Whether the sentence from token `index` ends with a question mark.
    private static func asksQuestion(from index: Int, in tokens: [String]) -> Bool {
        tokens[index...].first(where: endsSentence)?.last == "?"
    }

    private static func startsClause(_ index: Int, in tokens: [String]) -> Bool {
        starts(index, after: clauseEnders, in: tokens)
    }

    private static func startsSentence(_ index: Int, in tokens: [String]) -> Bool {
        starts(index, after: sentenceEnders, in: tokens)
    }

    /// Whether the token at `index` starts the text or follows one that ends with one of
    /// `enders`, perhaps with "and" or "then" between: "…, and second" / "and then third".
    private static func starts(_ index: Int, after enders: Set<Character>, in tokens: [String]) -> Bool {
        var previous = index - 1
        while previous >= 0 {
            if let last = tokens[previous].last, enders.contains(last) { return true }
            guard connectors.contains(core(tokens[previous])) else { return false }
            previous -= 1
        }
        return true
    }

    /// The token's word, lowercased, without the punctuation around it, with a typographic
    /// apostrophe written as "'" ("one’s" → "one's").
    private static func core(_ token: String) -> String {
        token.trimmingCharacters(in: .punctuationCharacters).lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
    }

    private static func endsSentence(_ token: String) -> Bool {
        token.last.map { sentenceEnders.contains($0) } ?? false
    }
}
