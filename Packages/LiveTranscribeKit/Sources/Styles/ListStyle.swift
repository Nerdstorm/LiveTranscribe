import Foundation
import Shared

/// How a list reads once laid out, whether it was spoken with ordinals ("first, …") or with
/// markers ("number one …", "bullet point …").
///
/// - The line before the list ends with a colon: "Tasks for the week." becomes "Tasks for the
///   week:". A question or exclamation keeps its mark.
/// - Items start with a capital and lose trailing commas and semicolons.
/// - Items keep their full stops only when every item is a sentence: it ended with a full stop,
///   question or exclamation mark, and has at least ``minimumSentenceWords`` words. "1. We have
///   to work on the launch." keeps its full stop; "1. Milk" and "1. Ship the release" do not.
///   Question and exclamation marks always stay.
public struct ListStyle: Sendable, Equatable {
    public static let defaultMinimumSentenceWords = 4
    private static let sentenceEnders: Set<Character> = [".", "!", "?"]

    /// Fewest words for an item to count as a sentence.
    public let minimumSentenceWords: Int

    public init(minimumSentenceWords: Int = defaultMinimumSentenceWords) {
        self.minimumSentenceWords = minimumSentenceWords
    }

    /// The line before a list, ending in a colon; `nil` for a blank line.
    public func leadIn(_ line: String) -> String? {
        var text = line.trimmingCharacters(in: .whitespaces)
        guard let last = text.last else { return nil }
        if last == ":" || last == "?" || last == "!" { return text }
        while let end = text.last, end == "." || end == "," || end == ";" || end.isWhitespace {
            text.removeLast()
        }
        return text.isEmpty ? nil : text + ":"
    }

    /// Items as they read in the list; see the type's rules.
    public func items(_ raw: [String]) -> [String] {
        let trimmed = raw.map { item in
            String(item.drop { $0 == "," || $0 == ";" || $0 == ":" || $0.isWhitespace })
                .trimmingCharacters(in: .whitespaces)
        }
        let allSentences = trimmed.allSatisfy { item in
            guard let last = item.last, Self.sentenceEnders.contains(last) else { return false }
            return item.split(whereSeparator: \.isWhitespace).count >= minimumSentenceWords
        }
        return trimmed.map { item in
            var text = item
            while let end = text.last, end == "," || end == ";" || end.isWhitespace || (!allSentences && end == ".") {
                text.removeLast()
            }
            return SentenceCase.capitalizingFirstWord(text)
        }
    }

    /// The marker a laid-out list line starts with, "1. " or "- "; `nil` for any other line.
    static func marker(of line: String) -> (prefix: String, isNumbered: Bool)? {
        if line.hasPrefix("- ") { return ("- ", false) }
        let digits = line.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 3, line.dropFirst(digits.count).hasPrefix(". ") else { return nil }
        return (digits + ". ", true)
    }

    /// `text` split after its first sentence, or `nil` when it is one sentence. The text after
    /// a list's last item follows the list on a line of its own.
    static func splitAfterFirstSentence(_ text: String) -> (sentence: String, rest: String)? {
        let tokens = text.split(whereSeparator: \.isWhitespace)
        guard let end = tokens.firstIndex(where: { $0.last.map(sentenceEnders.contains) ?? false }),
              end + 1 < tokens.count
        else { return nil }
        return (tokens[...end].joined(separator: " "), tokens[(end + 1)...].joined(separator: " "))
    }
}
