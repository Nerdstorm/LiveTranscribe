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
public struct ListFormatter: Sendable {
    private static let ordinals: [String: Int] = [
        "first": 1, "firstly": 1, "second": 2, "secondly": 2, "third": 3, "thirdly": 3,
        "fourth": 4, "fourthly": 4, "fifth": 5, "fifthly": 5, "sixth": 6, "seventh": 7,
        "eighth": 8, "ninth": 9, "tenth": 10,
    ]
    private static let closers: Set<String> = ["finally", "lastly"]
    private static let connectors: Set<String> = ["and", "then"]
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
            var start = marker + 1
            // "First of all, …"
            if Self.core(tokens[marker]) == "first", start + 1 < tokens.count,
               Self.core(tokens[start]) == "of", Self.core(tokens[start + 1]) == "all" {
                start += 2
            }
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

    private static func core(_ token: String) -> String {
        token.trimmingCharacters(in: .punctuationCharacters).lowercased()
    }

    private static func endsSentence(_ token: String) -> Bool {
        token.last.map { sentenceEnders.contains($0) } ?? false
    }
}
