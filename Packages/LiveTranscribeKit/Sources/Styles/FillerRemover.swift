import Foundation

/// Removes hesitation fillers ("um", "uh", "er") from a transcript, deterministically.
///
/// Only standalone filler words go; words that merely contain one ("umbrella", "uh-oh") stay,
/// and ambiguous fillers ("like", "you know") are left to the speaker. A sentence-final
/// punctuation mark on a removed filler moves to the word before it, and a sentence that
/// started with a filler starts with a capital again.
public struct FillerRemover: Sendable {
    /// Hesitation sounds that never carry meaning. Shared with the output guard, which lets the
    /// language model drop them too.
    public static let standardFillers = ["um", "umm", "uh", "uhh", "uhm", "erm", "er", "ah", "hmm", "hmmm"]

    private static let sentenceEnders: Set<Character> = [".", "!", "?", "…"]

    private let fillers: Set<String>

    public init(fillers: [String] = FillerRemover.standardFillers) {
        self.fillers = Set(fillers.map { $0.lowercased() })
    }

    public func removingFillers(from text: String) -> String {
        var kept: [String] = []
        var capitalizeNext = false
        for token in text.split(whereSeparator: \.isWhitespace).map(String.init) {
            let core = token.trimmingCharacters(in: .punctuationCharacters).lowercased()
            guard fillers.contains(core) else {
                kept.append(capitalizeNext ? Self.capitalizingFirstLetter(token) : token)
                capitalizeNext = false
                continue
            }
            let startsSentence = kept.last.map(Self.endsSentence) ?? true
            if startsSentence, token.first?.isUppercase == true {
                capitalizeNext = true
            }
            if let ender = token.last(where: { Self.sentenceEnders.contains($0) }), let last = kept.popLast() {
                kept.append(Self.endingSentence(last, with: ender))
            }
        }
        return kept.joined(separator: " ")
    }

    private static func endsSentence(_ token: String) -> Bool {
        token.last.map { sentenceEnders.contains($0) } ?? false
    }

    /// `token` with its trailing commas, semicolons and colons replaced by `ender`.
    private static func endingSentence(_ token: String, with ender: Character) -> String {
        if endsSentence(token) { return token }
        var trimmed = token
        while let last = trimmed.last, ",;:".contains(last) {
            trimmed.removeLast()
        }
        return trimmed + String(ender)
    }

    private static func capitalizingFirstLetter(_ token: String) -> String {
        guard let index = token.firstIndex(where: \.isLetter) else { return token }
        return token.replacingCharacters(in: index...index, with: token[index].uppercased())
    }
}
