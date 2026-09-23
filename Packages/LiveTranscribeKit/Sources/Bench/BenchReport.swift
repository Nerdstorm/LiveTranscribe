import Foundation
import Persistence
import Session
import Shared

enum BenchSession {
    /// Waits for one listening session to finish. Returns a failure description, or `nil`.
    static func awaitCompletion(of coordinator: SessionCoordinator) async -> String? {
        var sawListening = false
        var lastProgressLine = ""
        for await event in coordinator.events {
            switch event {
            case .modelProgress(let progress):
                let percent = progress.fractionCompleted.map { " \(Int($0 * 100))%" } ?? ""
                let line = "  \(progress.modelID): \(progress.stage.rawValue)\(percent)"
                if line != lastProgressLine {
                    print(line)
                    lastProgressLine = line
                }
            case .cleanupAvailability(.unavailable(let model, let message)):
                print("  cleanup unavailable (\(model)): \(message)")
            case .phase(.listening):
                sawListening = true
            case .phase(.ready) where sawListening:
                return nil
            case .phase(.failed(let failure)):
                return "\(failure)"
            default:
                break
            }
        }
        return "event stream ended"
    }
}

struct FixtureResult {
    let name: String
    let rawWER: Double
    let cleanedWER: Double
    let segments: Int
    let fallbacks: Int
    let latencies: [StageLatencies]

    init(name: String, reference: String, records: [SegmentRecord]) {
        let raw = records.map(\.rawText).joined(separator: " ")
        let cleaned = records.map { $0.cleanedText ?? $0.rawText }.joined(separator: " ")
        self.name = name
        self.rawWER = EditDistance.wordErrorRate(reference: reference, hypothesis: raw)
        self.cleanedWER = EditDistance.wordErrorRate(reference: reference, hypothesis: cleaned)
        self.segments = records.count
        self.fallbacks = records.filter(\.fellBack).count
        self.latencies = records.map(\.latency)
    }

    var summaryLine: String {
        name.padding(toLength: 24, withPad: " ", startingAt: 0) + String(
            format: " raw WER %5.1f%%  cleaned WER %5.1f%%  segments %d  fallbacks %d",
            rawWER * 100, cleanedWER * 100, segments, fallbacks
        )
    }
}

struct BenchReport {
    let results: [FixtureResult]
    let cleanupEnabled: Bool

    func print() {
        let latencies = results.flatMap(\.latencies)
        let segments = results.reduce(0) { $0 + $1.segments }
        let fallbacks = results.reduce(0) { $0 + $1.fallbacks }
        let meanRaw = results.map(\.rawWER).mean
        let meanCleaned = results.map(\.cleanedWER).mean
        let worstRegression = results.map { $0.cleanedWER - $0.rawWER }.max() ?? 0
        let fallbackRate = segments == 0 ? 0 : Double(fallbacks) / Double(segments)
        let totals = latencies.compactMap(\.totalMs)

        Swift.print("\nLatency (ms)      p50     p95")
        row("vad (silence)", latencies.map(\.vadMs))
        row("stt", latencies.map(\.sttMs))
        row("llm", latencies.compactMap(\.llmMs))
        row("end of speech → text", totals)

        Swift.print(String(format: "\nMean WER: raw %.1f%%, cleaned %.1f%%", meanRaw * 100, meanCleaned * 100))
        Swift.print("\nAcceptance")
        check("p95 end-of-speech → text < 1500 ms", (totals.percentile(0.95) ?? .max) < 1_500)
        if cleanupEnabled {
            check("cleaned WER ≤ raw WER", meanCleaned <= meanRaw + 1e-9)
            check("no clip regresses by more than 2 points", worstRegression <= 0.02 + 1e-9)
            check(String(format: "fallback rate < 5%% (%.1f%%)", fallbackRate * 100), fallbackRate < 0.05)
        }
    }

    private func row(_ label: String, _ values: [Int]) {
        guard let p50 = values.percentile(0.5), let p95 = values.percentile(0.95) else {
            Swift.print(label.padding(toLength: 20, withPad: " ", startingAt: 0) + "     –       –")
            return
        }
        Swift.print(label.padding(toLength: 20, withPad: " ", startingAt: 0) + String(format: "%6d  %6d", p50, p95))
    }

    private func check(_ label: String, _ passed: Bool) {
        Swift.print("  [\(passed ? "PASS" : "FAIL")] \(label)")
    }
}

extension Array where Element == Int {
    /// Nearest-rank percentile.
    func percentile(_ p: Double) -> Int? {
        guard !isEmpty else { return nil }
        let sorted = self.sorted()
        let rank = Int((p * Double(sorted.count)).rounded(.up))
        return sorted[Swift.min(Swift.max(rank, 1), sorted.count) - 1]
    }
}

extension Array where Element == Double {
    var mean: Double { isEmpty ? 0 : reduce(0, +) / Double(count) }
}
