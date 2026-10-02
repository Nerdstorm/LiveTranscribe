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
            if targetWords == inputWords {
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
        }
        return problems
    }

    private func words(_ text: String) -> [String] {
        EditDistance.words(in: EditDistance.normalize(text))
    }
}
