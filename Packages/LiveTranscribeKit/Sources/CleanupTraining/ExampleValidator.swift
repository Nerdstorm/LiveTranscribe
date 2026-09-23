import Cleanup
import Foundation
import Shared

/// Rejects examples that would teach the model something the app would not accept.
///
/// Every target must pass the production ``OutputGuard``, so the adapter is only ever trained
/// towards output the guard lets through, and each category must change the text only in the
/// way it describes.
public struct ExampleValidator: Sendable {
    public static let maxWords = 60

    private let outputGuard: OutputGuard

    public init(outputGuard: OutputGuard = OutputGuard()) {
        self.outputGuard = outputGuard
    }

    /// Why `example` is unusable; empty when it is fine.
    public func problems(in example: TrainingExample) -> [String] {
        var problems: [String] = []
        let rawWords = words(example.raw)
        let targetWords = words(example.target)
        if rawWords.isEmpty || targetWords.isEmpty {
            return ["empty raw or target"]
        }
        if rawWords.count > Self.maxWords {
            problems.append("raw has \(rawWords.count) words (max \(Self.maxWords))")
        }
        if example.context.contains(where: { words($0).isEmpty }) {
            problems.append("blank context line")
        }
        if outputGuard.review(raw: example.raw, outcome: .completed(example.target)) != .accepted(example.target) {
            problems.append("the output guard rejects the target")
        }

        let dropsCue = outputGuard.dropsCorrectionCue(raw: example.raw, cleaned: example.target)
        switch example.category {
        case .correction:
            if !dropsCue {
                problems.append("a correction must drop its cue")
            }
        case .control, .boundary:
            if dropsCue || rawWords != targetWords {
                problems.append("must keep every word; only casing and punctuation may change")
            }
            if outputGuard.correctionCueCount(in: example.raw) == 0 {
                problems.append("must contain a correction cue")
            }
        case .cleanup:
            if outputGuard.correctionCueCount(in: example.raw) > 0 {
                problems.append("cleanup examples must not contain a correction cue")
            }
            if targetWords != rawWords && targetWords != Self.withoutDoubledWords(rawWords) {
                problems.append("may only change casing and punctuation, or drop a doubled word")
            }
        }
        return problems
    }

    private func words(_ text: String) -> [String] {
        EditDistance.words(in: EditDistance.normalize(text))
    }

    static func withoutDoubledWords(_ words: [String]) -> [String] {
        var result: [String] = []
        for word in words where result.last != word {
            result.append(word)
        }
        return result
    }
}
