import Cleanup
import Foundation
import os
import Shared
import Styles

/// How a cleanup configuration does on a set of ``EvalCase``s, per category: how often the shown
/// text is right, falls back, changes the meaning, stays as it was, or is something else, and how
/// long it takes.
public struct MeasurementReport: Sendable, Codable {
    public struct Row: Sendable, Codable, Equatable {
        public var total = 0
        public var verdicts: [String: Int] = [:]
        public var latencyP50Ms = 0
        public var latencyP95Ms = 0

        public func count(_ verdict: EvalCase.Verdict) -> Int { verdicts[verdict.rawValue] ?? 0 }
    }

    /// One case's result, with every generation the model made for it.
    public struct Result: Sendable, Codable {
        public let id: String
        public let category: String
        public let raw: String
        public let target: String
        public let shown: String
        public let verdict: EvalCase.Verdict
        public let fallbackReason: String?
        public let latencyMs: Int
        public let generations: [Generation]
    }

    public struct Generation: Sendable, Codable, Equatable {
        public let output: String
        public let milliseconds: Int
        public let adapter: CleanupRequest.Adapter
        public let thinks: Bool
    }

    public var level: String
    public var configuration: String
    public var rows: [String: Row] = [:]
    public var overall = Row()
    public var results: [Result] = []

    public var summary: String {
        let verdicts = EvalCase.Verdict.allCases
        let header = "category          total " + verdicts.map { $0.rawValue.padding(toLength: 15, withPad: " ", startingAt: 0) }.joined()
            + "p50 ms  p95 ms"
        func line(_ name: String, _ row: Row) -> String {
            name.padding(toLength: 18, withPad: " ", startingAt: 0)
                + String(format: "%5d ", row.total)
                + verdicts.map { String(format: "%-15d", row.count($0)) }.joined()
                + String(format: "%6d  %6d", row.latencyP50Ms, row.latencyP95Ms)
        }
        let lines = rows.keys.sorted().map { line($0, rows[$0]!) }
        return ([configuration, header] + lines + [line("overall", overall)]).joined(separator: "\n")
    }
}

/// Collects the generations a ``MLXCleaner`` makes, through its observer.
public final class GenerationRecorder: Sendable {
    private let generations = OSAllocatedUnfairLock<[MeasurementReport.Generation]>(initialState: [])

    public init() {}

    public var observer: MLXCleaner.GenerationObserver {
        { [generations] request, output, duration in
            let generation = MeasurementReport.Generation(
                output: output,
                milliseconds: duration.wholeMilliseconds,
                adapter: request.adapter,
                thinks: request.thinks
            )
            generations.withLock { $0.append(generation) }
        }
    }

    /// The generations since the last call.
    public func take() -> [MeasurementReport.Generation] {
        generations.withLock { taken in
            defer { taken = [] }
            return taken
        }
    }
}

public enum CleanupMeasurement {
    /// Cleans every case through `cleaner` at `level`, one at a time as the app does, and judges
    /// what would be shown. At a level that removes fillers, so do the targets: the model never
    /// sees them.
    public static func run(
        _ cases: [EvalCase],
        with cleaner: any Cleaner,
        level: CleanupLevel,
        configuration: String,
        recorder: GenerationRecorder?,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) async -> MeasurementReport {
        var report = MeasurementReport(level: level.rawValue, configuration: configuration)
        for (index, evalCase) in cases.enumerated() {
            let segment = Segment(id: UUID(), sessionID: UUID(), startMs: 0, endMs: 1_000, rawText: evalCase.raw)
            let options = evalCase.options(level: level)
            _ = recorder?.take()
            let cleaned = await cleaner.clean(segment, context: evalCase.context, options: options)
            report.add(evalCase, cleaned: cleaned, level: level, generations: recorder?.take() ?? [])
            if (index + 1) % 25 == 0 {
                log("Measured \(index + 1)/\(cases.count)")
            }
        }
        report.finish()
        return report
    }

    /// Replays recorded model outputs, one per case, through the app's cleanup policy and output
    /// guard, as if the model had just written them: for scoring another runtime's outputs (the
    /// Linux and Windows app's) exactly as the Mac scores its own. A second pass, as High and Deep
    /// may make, has no recorded output and fails, so its first pass's result stands.
    public static func replay(
        _ cases: [EvalCase],
        outputs: [String: String],
        executor: CleanupExecutor,
        level: CleanupLevel,
        configuration: String
    ) async -> MeasurementReport {
        var report = MeasurementReport(level: level.rawValue, configuration: configuration)
        for evalCase in cases {
            guard let output = outputs[evalCase.id] else { continue }
            let segment = Segment(id: UUID(), sessionID: UUID(), startMs: 0, endMs: 1_000, rawText: evalCase.raw)
            let options = evalCase.options(level: level)
            let calls = OSAllocatedUnfairLock(initialState: 0)
            let cleaned = await executor.run(segment, context: evalCase.context, options: options) { _ in
                let call = calls.withLock { count in
                    count += 1
                    return count
                }
                guard call == 1 else { throw ReplayHasNoSecondPass() }
                return output
            }
            report.add(evalCase, cleaned: cleaned, level: level, generations: [])
        }
        report.finish()
        return report
    }

    /// The request the app's first pass sends for each case, as JSON Lines in the format other
    /// runtimes read (see Training/README.md), naming the adapter it runs with when the model has
    /// `adapters` loaded, as ``MLXCleaner`` chooses it.
    public static func requests(
        _ cases: [EvalCase], executor: CleanupExecutor, level: CleanupLevel, adapters: Set<CleanupRequest.Adapter>
    ) async -> [RequestLine] {
        var lines: [RequestLine] = []
        for evalCase in cases {
            let segment = Segment(id: UUID(), sessionID: UUID(), startMs: 0, endMs: 1_000, rawText: evalCase.raw)
            let options = evalCase.options(level: level)
            let captured = OSAllocatedUnfairLock<CleanupRequest?>(initialState: nil)
            _ = await executor.run(segment, context: evalCase.context, options: options) { request in
                captured.withLock { $0 = $0 ?? request }
                throw ReplayHasNoSecondPass()
            }
            if var request = captured.withLock({ $0 }) {
                request.adapter = request.adapter.resolved(loaded: adapters)
                lines.append(RequestLine(id: evalCase.id, request: request))
            }
        }
        return lines
    }

    struct ReplayHasNoSecondPass: Error {}
}

/// One request in the JSON Lines format shared with the Linux and Windows app's benchmark.
public struct RequestLine: Sendable, Codable, Equatable {
    public struct Message: Sendable, Codable, Equatable {
        public let role: String
        public let content: String
    }

    public struct Sampling: Sendable, Codable, Equatable {
        public let temperature: Float
        public let topP: Float
        public let topK: Int
        public let seed: UInt64?

        enum CodingKeys: String, CodingKey {
            case temperature
            case topP = "top_p"
            case topK = "top_k"
            case seed
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(temperature, forKey: .temperature)
            try container.encode(topP, forKey: .topP)
            try container.encode(topK, forKey: .topK)
            try container.encode(seed, forKey: .seed)
        }
    }

    public let id: String
    public let messages: [Message]
    public let thinking: Bool
    public let maxTokens: Int
    /// The adapter to generate with: `none`, `medium` or `deep`.
    public let adapter: CleanupRequest.Adapter
    public let sampling: Sampling

    enum CodingKeys: String, CodingKey {
        case id, messages, thinking
        case maxTokens = "max_tokens"
        case adapter, sampling
    }

    public init(id: String, request: CleanupRequest) {
        self.id = id
        messages = request.messages.map { Message(role: $0.role.rawValue, content: $0.content) }
        thinking = request.thinks
        maxTokens = request.maxTokens
        adapter = request.adapter
        sampling = Sampling(
            temperature: request.sampling.temperature,
            topP: request.sampling.topP,
            topK: request.sampling.topK,
            seed: request.sampling.seed
        )
    }
}

/// One output in the JSON Lines format the Linux and Windows app's benchmark writes.
public struct OutputLine: Sendable, Codable, Equatable {
    public let id: String
    public let output: String?
    public let error: String?
}

extension MeasurementReport {
    mutating func add(_ evalCase: EvalCase, cleaned: CleanedSegment, level: CleanupLevel, generations: [Generation]) {
        let fillers = FillerRemover()
        // Line by line, so a laid-out target keeps its lines.
        func withoutFillers(_ text: String) -> String {
            text.components(separatedBy: "\n").map { $0.isEmpty ? $0 : fillers.removingFillers(from: $0) }.joined(separator: "\n")
        }
        var expected = evalCase
        if level.removesFillers {
            expected.target = withoutFillers(evalCase.target)
            expected.alternatives = evalCase.alternatives.map(withoutFillers)
        }
        let input = CleanupExecutor.deterministicCleanup(of: evalCase.raw, level: level)
        let verdict = expected.judge(shown: cleaned.cleanedText, fellBack: cleaned.fellBack, input: input, level: level)
        results.append(Result(
            id: evalCase.id,
            category: evalCase.category,
            raw: evalCase.raw,
            target: expected.target,
            shown: cleaned.cleanedText,
            verdict: verdict,
            fallbackReason: cleaned.fallbackReason,
            latencyMs: cleaned.latencyMs,
            generations: generations
        ))
    }

    /// Counts the results into rows and works out their latencies.
    mutating func finish() {
        var byCategory: [String: [Result]] = [:]
        for result in results { byCategory[result.category, default: []].append(result) }
        rows = byCategory.mapValues(Self.row)
        overall = Self.row(results)
    }

    private static func row(_ results: [Result]) -> Row {
        var row = Row()
        row.total = results.count
        for result in results { row.verdicts[result.verdict.rawValue, default: 0] += 1 }
        let latencies = results.map(\.latencyMs).sorted()
        row.latencyP50Ms = AdapterEvaluator.percentile(latencies, 0.5)
        row.latencyP95Ms = AdapterEvaluator.percentile(latencies, 0.95)
        return row
    }
}
