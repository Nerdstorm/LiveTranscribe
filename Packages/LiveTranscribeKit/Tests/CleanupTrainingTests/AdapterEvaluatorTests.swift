import Cleanup
@testable import CleanupTraining
import Foundation
import Shared
import Testing

@Suite("AdapterEvaluator")
struct AdapterEvaluatorTests {
    /// Answers from a fixed table, falling back to the raw text for anything else.
    private actor TableCleaner: Cleaner {
        let answers: [String: String]

        init(_ answers: [String: String]) {
            self.answers = answers
        }

        func load(progress: @escaping ModelLoadProgressHandler) async throws {}

        func clean(_ segment: Segment, context: [String], options: CleanupOptions) async -> CleanedSegment {
            guard let answer = answers[segment.rawText] else {
                return .fallback(segment, reason: "no answer", latencyMs: 5)
            }
            return CleanedSegment(segment: segment, cleanedText: answer, fellBack: false, fallbackReason: nil, latencyMs: 10)
        }
    }

    @Test func scoresShownTextAgainstTheTargetPerCategory() async {
        let examples = [
            TrainingExample(category: .correction, raw: "cars sorry buses", target: "Buses.", source: "test"),
            TrainingExample(category: .correction, raw: "two i mean three", target: "Three.", source: "test"),
            TrainingExample(category: .control, raw: "sorry i'm late", target: "Sorry I'm late.", source: "test"),
        ]
        let cleaner = TableCleaner([
            "cars sorry buses": "buses",  // casing and punctuation are ignored
            "sorry i'm late": "Sorry, I'm late.",
        ])
        let report = await AdapterEvaluator.evaluate(examples, with: cleaner, options: CleanupOptions(level: .light))

        #expect(report.scores[.correction] == EvaluationReport.Score(total: 2, matched: 1, fellBack: 1))
        #expect(report.scores[.control] == EvaluationReport.Score(total: 1, matched: 1, fellBack: 0))
        #expect(report.overall.matched == 2)
        #expect(report.misses.count == 1)
        #expect(report.misses.first?.shown == "two i mean three")
        #expect(report.misses.first?.fallbackReason == "no answer")
    }

    @Test func atALevelThatRemovesFillersTheTargetLosesThemToo() async {
        let examples = [TrainingExample(category: .cleanup, raw: "so um it works", target: "So, um, it works.", source: "test")]
        let cleaner = TableCleaner(["so um it works": "So it works."])
        let medium = await AdapterEvaluator.evaluate(examples, with: cleaner, options: CleanupOptions(level: .medium))
        #expect(medium.overall.matched == 1)
        let light = await AdapterEvaluator.evaluate(examples, with: cleaner, options: CleanupOptions(level: .light))
        #expect(light.overall.matched == 0)
        #expect(light.misses.first?.expected == "So, um, it works.")
    }

    @Test func percentilesUseTheNearestRank() {
        #expect(AdapterEvaluator.percentile([], 0.5) == 0)
        #expect(AdapterEvaluator.percentile([10, 20, 30, 40], 0.5) == 20)
        #expect(AdapterEvaluator.percentile([10, 20, 30, 40], 0.95) == 40)
    }

    @Test func reportsEncodeCategoriesAsKeys() throws {
        var report = EvaluationReport()
        report.scores[.cleanup] = .init(total: 1, matched: 1, fellBack: 0)
        let json = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        #expect(json.contains(#""cleanup":{"#))
    }
}
