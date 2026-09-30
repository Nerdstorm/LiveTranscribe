import Cleanup
import CleanupTraining
import Foundation
import MLXSupport
import Shared

// The commands that measure a cleanup configuration through the app's own cleanup: measure,
// requests and replay. See Training/README.md.

/// Cleans every case at one level through the real model, as the app does, and reports what was
/// shown per category (right, fell back, changed the meaning, unchanged, different) with latency.
func measure(_ options: MeasureCommandOptions) async throws {
    let settings = AppSettings.defaults
    let cases = try options.cases()
    for directory in [options.adapterDirectory, options.deepAdapterDirectory].compactMap(\.self)
    where try CleanupAdapter.load(from: directory) == nil {
        throw TrainError.noAdapter(directory.relativePath)
    }
    let configuration = options.configuration(settings: settings)
    print("Measuring \(options.label) on \(cases.count) cases")

    MLXRuntime.configure(gpuCacheLimitMB: settings.gpuCacheLimitMB)
    let recorder = GenerationRecorder()
    let cleaner = MLXCleaner(configuration: configuration, observer: recorder.observer)
    try await cleaner.load { _ in }
    if configuration.adapter != nil, await cleaner.activeAdapter == nil {
        throw TrainError.adapterNotApplied
    }
    if configuration.deepAdapter != nil, await cleaner.activeDeepAdapter == nil {
        throw TrainError.adapterNotApplied
    }
    let report = await CleanupMeasurement.run(
        cases, with: cleaner, level: options.level, configuration: options.label, recorder: recorder
    ) { print($0) }
    for result in report.results where result.verdict != .right && result.verdict != .unchanged {
        print("\(result.verdict.rawValue.uppercased()) \(result.id)\(result.fallbackReason.map { " (\($0))" } ?? "")")
        print("    raw:      \(result.raw)")
        print("    expected: \(result.target)")
        print("    shown:    \(result.shown)")
    }
    print(report.summary)
    if let reportURL = options.report {
        try writeJSON(report, to: reportURL)
        print("Report in \(reportURL.relativePath)")
    }
}

/// Writes the request the app's first pass sends for each case, for another runtime to answer.
func writeRequests(_ options: MeasureCommandOptions, to output: URL) async throws {
    let settings = AppSettings.defaults
    let cases = try options.cases()
    let executor = options.executor(settings: settings)
    let adapters = Set(MLXCleaner.compatibleAdapters(in: options.configuration(settings: settings)).keys)
    let lines = await CleanupMeasurement.requests(cases, executor: executor, level: options.level, adapters: adapters)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let text = try lines.map { String(decoding: try encoder.encode($0), as: UTF8.self) }.joined(separator: "\n") + "\n"
    try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: output, atomically: true, encoding: .utf8)
    print("\(lines.count) requests (\(cases.count - lines.count) cases need no model) in \(output.path)")
}

/// Scores another runtime's outputs for the cases, through the app's cleanup policy and guard.
func replay(_ options: MeasureCommandOptions, outputs: URL) async throws {
    let settings = AppSettings.defaults
    let cases = try options.cases()
    let decoder = JSONDecoder()
    var answers: [String: String] = [:]
    var errors = 0
    for line in try String(contentsOf: outputs, encoding: .utf8).split(separator: "\n") where !line.isEmpty {
        let output = try decoder.decode(OutputLine.self, from: Data(line.utf8))
        if let text = output.output, output.error == nil { answers[output.id] = text } else { errors += 1 }
    }
    let report = await CleanupMeasurement.replay(
        cases, outputs: answers, executor: options.executor(settings: settings), level: options.level,
        configuration: "\(options.label), replaying \(outputs.lastPathComponent)"
    )
    print(report.summary)
    print("\(answers.count) outputs replayed, \(errors) failed generations, \(cases.count - report.results.count) cases without an output")
    if let reportURL = options.report {
        try writeJSON(report, to: reportURL)
        print("Report in \(reportURL.relativePath)")
    }
}

/// A cleanup configuration to measure: the level, the model's options and the cases.
struct MeasureCommandOptions {
    var level = CleanupLevel.medium
    var data: [URL] = []
    /// Whether to load the adapters; `--no-adapter` measures the base model.
    var adapters = true
    /// A self-correction adapter to use instead of the bundled one.
    var adapterDirectory: URL?
    /// A Deep adapter to use instead of the bundled one.
    var deepAdapterDirectory: URL?
    var timeoutSeconds: Double?
    var deep = DeepCleanup.shipped
    /// Names the configuration in the report; by default, its options.
    var labelOverride: String?
    var report: URL?

    var label: String {
        labelOverride ?? "\(level.rawValue)\(adapters ? "" : ", no adapter")"
            + (level.repairsAcrossSentences
                ? ", \(deep.passes.rawValue) pass\(deep.passes == .one ? "" : "es"), \(deep.adapter.rawValue) adapter, thinking \(deep.thinking ? "on (\(deep.thinkingTokens) tokens)" : "off")"
                    + (deep.fallsBackToMedium ? ", Medium on rejection" : "")
                : "")
    }

    func cases() throws -> [EvalCase] {
        let files = data.isEmpty ? try Paths.testFiles() : data
        return try files.flatMap { try EvalCase.read(from: $0) }
    }

    func configuration(settings: AppSettings) -> MLXCleaner.Configuration {
        MLXCleaner.Configuration(
            modelID: settings.llmModel,
            contextSegments: settings.contextSegments,
            timeoutSeconds: timeoutSeconds ?? settings.cleanupTimeoutSeconds,
            adapter: adapters ? (adapterDirectory.flatMap { try? CleanupAdapter.load(from: $0) } ?? CleanupAdapter.bundled(.medium)) : nil,
            deepAdapter: adapters ? (deepAdapterDirectory.flatMap { try? CleanupAdapter.load(from: $0) } ?? CleanupAdapter.bundled(.deep)) : nil,
            deep: deep
        )
    }

    func executor(settings: AppSettings) -> CleanupExecutor {
        let configuration = configuration(settings: settings)
        return CleanupExecutor(
            contextLimit: configuration.contextSegments,
            timeoutSeconds: configuration.timeoutSeconds,
            prompts: configuration.prompts(adapted: configuration.adapter != nil),
            deep: deep
        )
    }

    /// Reads one of the options every measuring command shares; `false` when `argument` isn't one.
    mutating func parse(_ argument: String, value: () throws -> String) throws -> Bool {
        switch argument {
        case "--level":
            let text = try value()
            guard let level = CleanupLevel(rawValue: text) else {
                throw TrainError.usage("--level needs one of \(CleanupLevel.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            self.level = level
        case "--data": data.append(URL(fileURLWithPath: try value()))
        case "--no-adapter": adapters = false
        case "--adapter": adapterDirectory = URL(fileURLWithPath: try value(), isDirectory: true)
        case "--deep-adapter-dir": deepAdapterDirectory = URL(fileURLWithPath: try value(), isDirectory: true)
        case "--timeout":
            guard let seconds = Double(try value()), seconds > 0 else { throw TrainError.usage("--timeout needs seconds") }
            timeoutSeconds = seconds
        case "--thinking": deep.thinking = true
        case "--no-thinking": deep.thinking = false
        case "--thinking-tokens":
            guard let tokens = Int(try value()), tokens > 0 else { throw TrainError.usage("--thinking-tokens needs a number") }
            deep.thinkingTokens = tokens
        case "--deep-passes":
            let text = try value()
            guard let passes = DeepCleanup.Passes(argument: text) else { throw TrainError.usage("--deep-passes needs one or after-medium") }
            deep.passes = passes
        case "--deep-adapter":
            guard let adapter = CleanupRequest.Adapter(rawValue: try value()) else {
                throw TrainError.usage("--deep-adapter needs one of \(CleanupRequest.Adapter.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            deep.adapter = adapter
        case "--no-medium-fallback": deep.fallsBackToMedium = false
        case "--label": labelOverride = try value()
        case "--report": report = URL(fileURLWithPath: try value())
        default: return false
        }
        return true
    }
}

extension DeepCleanup.Passes {
    init?(argument: String) {
        switch argument {
        case "one": self = .one
        case "after-medium": self = .afterMedium
        default: return nil
        }
    }
}
