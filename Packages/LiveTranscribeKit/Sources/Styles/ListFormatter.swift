import Foundation

/// Turns a spoken enumeration into a numbered list: "We need three things: first, milk; second,
/// eggs; and third, bread." becomes "We need three things:\n1. Milk\n2. Eggs\n3. Bread".
///
/// Deterministic, so it never changes words: it only moves them onto lines. A list needs spoken
/// ordinals in order from "first", each starting a clause (at the start of the text, after
/// punctuation, or after "and" / "then"), at least two of them; "finally" or "lastly" may end
/// it. The last item runs to the end of its sentence, and any text after that follows the list
/// on its own line.
public struct ListFormatter: Sendable {
    private static let ordinals: [String: Int] = [
        "first": 1, "firstly": 1, "second": 2, "secondly": 2, "third": 3, "thirdly": 3,
        "fourth": 4, "fourthly": 4, "fifth": 5, "fifthly": 5, "sixth": 6, "seventh": 7,
        "eighth": 8, "ninth": 9, "tenth": 10,
    ]
    private static let closers: Set<String> = ["finally", "lastly"]
    private static let connectors: Set<String> = ["and", "then"]
    private static let clauseEnders: Set<Character> = [",", ".", ";", ":", "!", "?"]
    private static let sentenceEnders: Set<Character> = [".", "!", "?"]

    public init() {}

    /// `text` as a numbered list, or `nil` when it is not a spoken enumeration.
    public func formatted(_ text: String) -> String? {
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
            guard start < end, let item = Self.item(from: tokens[start..<end]) else { return nil }
            items.append(item)
        }

        var lines: [String] = []
        if let leadIn = Self.leadIn(from: tokens[..<markers[0]]) {
            lines.append(leadIn)
        }
        lines += items.enumerated().map { "\($0.offset + 1). \($0.element)" }
        let lastItemEnd = tokens[(markers.last! + 1)...].firstIndex(where: Self.endsSentence).map { $0 + 1 } ?? tokens.count
        if lastItemEnd < tokens.count {
            lines.append(tokens[lastItemEnd...].joined(separator: " "))
        }
        return lines.joined(separator: "\n")
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

    /// The words before the first ordinal, ending in a colon unless they end a sentence.
    private static func leadIn(from tokens: ArraySlice<String>) -> String? {
        guard !tokens.isEmpty else { return nil }
        var text = tokens.joined(separator: " ")
        if let last = text.last, sentenceEnders.contains(last) || last == ":" {
            return text
        }
        while let last = text.last, ",;".contains(last) {
            text.removeLast()
        }
        return text.isEmpty ? nil : text + ":"
    }

    private static func item(from tokens: ArraySlice<String>) -> String? {
        var text = tokens.joined(separator: " ")
        while let first = text.first, ",:;".contains(first) || first.isWhitespace {
            text.removeFirst()
        }
        while let last = text.last, ",;.".contains(last) || last.isWhitespace {
            text.removeLast()
        }
        guard let first = text.first else { return nil }
        return first.uppercased() + text.dropFirst()
    }

    private static func core(_ token: String) -> String {
        token.trimmingCharacters(in: .punctuationCharacters).lowercased()
    }

    private static func endsSentence(_ token: String) -> Bool {
        token.last.map { sentenceEnders.contains($0) } ?? false
    }
}
