import Foundation
import Shared

/// Turns a spoken enumeration into a numbered list: "We need three things: first, milk; second,
/// eggs; and third, bread." becomes "We need three things:\n1. Milk\n2. Eggs\n3. Bread".
///
/// Deterministic, so it never changes words: it only moves them onto lines. A list needs spoken
/// ordinals in order from "first", each starting a clause (at the start of the text, after
/// punctuation, or after "and" / "then"), at least two of them; "finally" or "lastly" may end
/// it. The last item runs to the end of its sentence, and any text after that follows the list
/// on its own line. The lead-in and items are punctuated by ``ListStyle``.
///
/// Words that only introduce an item belong to its ordinal: "First of all, …", "First is …",
/// "Second thing is …", "Third one's …". The "is" stays in the item after a comma ("First, is
/// it ready?") or in a question ("First is it ready?").
public struct ListFormatter: Sendable {
    private static let ordinals: [String: Int] = [
        "first": 1, "firstly": 1, "second": 2, "secondly": 2, "third": 3, "thirdly": 3,
        "fourth": 4, "fourthly": 4, "fifth": 5, "fifthly": 5, "sixth": 6, "seventh": 7,
        "eighth": 8, "ninth": 9, "tenth": 10,
    ]
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
            let start = Self.itemStart(after: marker, in: tokens)
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
        let lastItemEnd = tokens[(markers.last! + 1)...].firstIndex(where: Self.endsSentence).map { $0 + 1 } ?? tokens.count
        if lastItemEnd < tokens.count {
            lines.append(tokens[lastItemEnd...].joined(separator: " "))
        }
        return lines
    }

    /// Token indices of the list's ordinals, in order, starting at "first".
    private func markers(in tokens: [String]) -> [Int]? {
        guard let first = tokens.indices.first(where: { Self.ordinals[Self.core(tokens[$0])] == 1 && startsClause($0, in: tokens) })
        else { return nil }
        var markers = [first]
        var expected = 2
        for index in (first + 1)..<tokens.count where startsClause(index, in: tokens) {
            let word = Self.core(tokens[index])
            if Self.ordinals[word] == expected {
                markers.append(index)
                expected += 1
            } else if Self.closers.contains(word), markers.count >= 2 {
                markers.append(index)
                break
            }
        }
        return markers
    }

    /// Where the item introduced by the ordinal at `marker` starts: after the words that belong
    /// to the marker (see the type's rules).
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

    private func startsClause(_ index: Int, in tokens: [String]) -> Bool {
        guard index > 0 else { return true }
        if let last = tokens[index - 1].last, Self.clauseEnders.contains(last) { return true }
        // "…, and second" / "and then third"
        var previous = index - 1
        while previous >= 0, Self.connectors.contains(Self.core(tokens[previous])) {
            if previous == 0 { return true }
            if let last = tokens[previous - 1].last, Self.clauseEnders.contains(last) { return true }
            previous -= 1
        }
        return false
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
