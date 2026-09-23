import Cleanup
import Foundation
import Shared
import Styles

/// How a cleaner does on a set of examples, measured on the text the app would show.
public struct EvaluationReport: Sendable, Codable {
    public struct Score: Sendable, Codable, Equatable {
        public var total = 0
        /// Shown text matches the target, ignoring casing and punctuation.
        public var matched = 0
        /// The output guard rejected the answer, so the raw text was shown.
        public var fellBack = 0

        public var rate: Double { total == 0 ? 0 : Double(matched) / Double(total) }
    }

    public struct Miss: Sendable, Codable {
        public let category: TrainingExample.Category
        public let raw: String
        public let expected: String
        public let shown: String
        public let fallbackReason: String?
    }

    public var scores: [TrainingExample.Category: Score] = [:]
    public var misses: [Miss] = []
    public var latencyP50Ms = 0
    public var latencyP95Ms = 0

    public var overall: Score {
        scores.values.reduce(into: Score()) { total, score in
            total.total += score.total
            total.matched += score.matched
            total.fellBack += score.fellBack
        }
    }

    public var summary: String {
        var lines = TrainingExample.Category.allCases.compactMap { category -> String? in
            guard let score = scores[category], score.total > 0 else { return nil }
            return String(
                format: "%-11@ %4d/%-4d matched (%5.1f%%), %d fell back",
                category.rawValue as NSString, score.matched, score.total, score.rate * 100, score.fellBack
            )
        }
        let all = overall
        lines.append(String(format: "overall     %4d/%-4d matched (%5.1f%%), %d fell back", all.matched, all.total, all.rate * 100, all.fellBack))
        lines.append("latency     p50 \(latencyP50Ms) ms, p95 \(latencyP95Ms) ms")
        return lines.joined(separator: "\n")
    }
}

public enum AdapterEvaluator {
    /// Cleans every example through `cleaner` at `options`, exactly as the app would, and scores
    /// the result. At a level that removes fillers, so does the expected text: the model never
    /// sees them.
    public static func evaluate(
        _ examples: [TrainingExample],
        with cleaner: any Cleaner,
        options: CleanupOptions,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) async -> EvaluationReport {
        let fillerRemover = FillerRemover()
        var report = EvaluationReport()
        var latencies: [Int] = []
        for (index, example) in examples.enumerated() {
            let segment = Segment(id: UUID(), sessionID: UUID(), startMs: 0, endMs: 1_000, rawText: example.raw)
            let cleaned = await cleaner.clean(segment, context: example.context, options: options)
            latencies.append(cleaned.latencyMs)

            let expected = options.level.removesFillers ? fillerRemover.removingFillers(from: example.target) : example.target
            let matched = EditDistance.normalize(cleaned.cleanedText) == EditDistance.normalize(expected)
            var score = report.scores[example.category] ?? .init()
            score.total += 1
            if matched { score.matched += 1 }
            if cleaned.fellBack { score.fellBack += 1 }
            report.scores[example.category] = score
            if !matched {
                report.misses.append(.init(
                    category: example.category,
                    raw: example.raw,
                    expected: expected,
                    shown: cleaned.cleanedText,
                    fallbackReason: cleaned.fallbackReason
                ))
            }
            if (index + 1) % 50 == 0 {
                log("Evaluated \(index + 1)/\(examples.count)")
            }
        }
        latencies.sort()
        report.latencyP50Ms = percentile(latencies, 0.5)
        report.latencyP95Ms = percentile(latencies, 0.95)
        return report
    }

    /// Nearest-rank percentile of sorted values.
    static func percentile(_ sorted: [Int], _ fraction: Double) -> Int {
        guard !sorted.isEmpty else { return 0 }
        let rank = Int((fraction * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }
}
