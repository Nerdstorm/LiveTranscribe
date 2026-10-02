import Cleanup
import Foundation
import Shared

/// Rejects Deep examples that would teach the model something the app would not show.
///
/// Every target must pass Deep's own output guard for the text the model is given (fillers
/// removed, as at inference) and the example's field, so the adapter is only ever trained towards
/// output the guard lets through; and each category must change the text only in its own way.
public struct DeepExampleValidator: Sendable {
    public static let maxWords = 90

    private let outputGuard: OutputGuard

    public init(outputGuard: OutputGuard = OutputGuard()) {
        self.outputGuard = outputGuard
    }

    /// Why `example` is unusable; empty when it is fine.
    public func problems(in example: DeepExample) -> [String] {
        let input = CleanupExecutor.deterministicCleanup(of: example.raw, level: .deep)
        let inputWords = words(input)
        let targetWords = words(example.target)
        guard !inputWords.isEmpty, !targetWords.isEmpty else { return ["empty raw or target"] }
        var problems: [String] = []
        if inputWords.count > Self.maxWords {
            problems.append("raw has \(inputWords.count) words (max \(Self.maxWords))")
        }
        if example.context.contains(where: { words($0).isEmpty }) {
            problems.append("blank context line")
        }
        let options = CleanupOptions(
            level: .deep,
            placeholders: PlaceholderToken.tokens(in: input),
            multiline: example.multiline,
            letterBody: example.letterBody
        )
        if outputGuard.review(raw: input, outcome: .completed(example.target), options: options) != .accepted(example.target) {
            problems.append("Deep's output guard rejects the target")
        }

        let cuesSaid = outputGuard.correctionCueCount(in: input)
        let cuesWritten = outputGuard.correctionCueCount(in: example.target)
        let laidOut = example.target.contains(where: \.isNewline)
        switch example.category {
        case .crossSentence, .malformed, .sameSentence:
            if cuesWritten >= cuesSaid {
                problems.append("a correction must take its cue out")
            }
        case .control:
            if cuesSaid == 0 {
                problems.append("must contain a correction cue")
            }
            if targetWords != inputWords {
                problems.append("must keep every word; only casing and punctuation may change")
            }
        case .facts, .unchanged:
            if targetWords != inputWords && targetWords != ExampleValidator.withoutDoubledWords(inputWords) {
                problems.append("may only change casing and punctuation, or drop a doubled word")
            }
        case .grammar, .recognition:
            // A common word speech-to-text wrote as a name ("in the Summer") is fixed by its capital.
            let recapitalised = example.category == .recognition && Self.recapitalises(from: input, to: example.target)
            if targetWords == inputWords && !recapitalised {
                problems.append("must fix a word")
            }
            if cuesSaid > 0 {
                problems.append("must not contain a correction cue")
            }
        case .layout:
            if !example.multiline || !laidOut {
                problems.append("must lay the text out in a field that takes several lines")
            }
        case .oneLine:
            if example.multiline || laidOut {
                problems.append("must stay on one line in a one-line field")
            }
        case .listTwo, .listMany:
            // Laid out where lines are allowed, and kept as said (casing and punctuation aside)
            // where they are not. Two bulleted things are a list only where the speaker set them
            // off, with a colon or the full stop speech-to-text often writes in its place, which
            // the guard checks.
            if example.multiline != laidOut {
                problems.append(example.multiline ? "must lay the list out" : "must stay on one line in a one-line field")
            }
            if !laidOut, targetWords != inputWords {
                problems.append("a list that stays keeps every word")
            }
        case .series:
            if laidOut || targetWords != inputWords {
                problems.append("a series stays in its sentence, every word kept")
            }
        case .body:
            if !example.letterBody || !example.multiline {
                problems.append("an email body is sent with the letter flag, in a field that takes several lines")
            }
        case .placeholder:
            if PlaceholderToken.tokens(in: example.raw).isEmpty {
                problems.append("must contain a placeholder token")
            }
            if example.letterBody, !example.multiline, laidOut {
                problems.append("text with spoken layout stays one paragraph")
            }
        case .mention:
            if cuesWritten > cuesSaid {
                problems.append("a correction takes its cue out; it doesn't add one")
            }
        case .composite:
            // Each dictation joined is checked as part of the whole, by the guard above.
            if laidOut {
                problems.append("dictations joined stay paragraphs, not a layout")
            }
        }
        return problems
    }

    private func words(_ text: String) -> [String] {
        EditDistance.words(in: EditDistance.normalize(text))
    }

    /// Whether `target` writes a word of `input` with another capital where neither starts a
    /// sentence or a line, the words being otherwise the same.
    static func recapitalises(from input: String, to target: String) -> Bool {
        let said = casedWords(in: input)
        let written = casedWords(in: target)
        guard said.count == written.count else { return false }
        return zip(said, written).contains { said, written in
            !said.startsSentence && !written.startsSentence
                && said.word != written.word && said.word.lowercased() == written.word.lowercased()
        }
    }

    /// The words of `text` with their case, split as ``EditDistance/normalize(_:)`` splits them,
    /// each with whether it starts a sentence or a line.
    private static func casedWords(in text: String) -> [(word: String, startsSentence: Bool)] {
        let edges = CharacterSet.punctuationCharacters.union(.symbols).subtracting(CharacterSet(charactersIn: "'\u{2019}"))
        var words: [(word: String, startsSentence: Bool)] = []
        for line in text.split(whereSeparator: \.isNewline) {
            var startsSentence = true
            for chunk in line.split(whereSeparator: { $0.isWhitespace || "-\u{2014}\u{2013}".contains($0) }) {
                let word = chunk.trimmingCharacters(in: edges).trimmingCharacters(in: CharacterSet(charactersIn: "'\u{2019}"))
                if !word.isEmpty {
                    words.append((word, startsSentence))
                }
                startsSentence = chunk.contains(where: { ".?!".contains($0) })
                    && chunk.trimmingCharacters(in: CharacterSet(charactersIn: "\"')]\u{201D}\u{2019}")).last.map { ".?!".contains($0) } == true
            }
        }
        return words
    }
}
