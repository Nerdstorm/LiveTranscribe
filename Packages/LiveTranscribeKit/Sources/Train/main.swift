// Train: builds the self-correction dataset, then trains and evaluates the cleanup model's LoRA
// adapter. Build with xcodebuild (MLX needs its Metal library) and run from
// Packages/LiveTranscribeKit; see Training/README.md.
//
//   Train generate [--seed <n>]
//   Train validate
//   Train train [--output <dir>] [--revision <commit>] [--iterations <n>] [--batch-size <n>]
//               [--learning-rate <x>] [--rank <n>] [--scale <x>] [--layers <n>]
//               [--curated-repeats <n>] [--seed <n>]
//   Train evaluate [--adapter <dir> | --no-adapter] [--data <file.jsonl>]... [--report <file>]

import Cleanup
import CleanupTraining
import Foundation
import MLXSupport
import Shared

setvbuf(stdout, nil, _IOLBF, 0)

do {
    let command = try Command.parse(Array(CommandLine.arguments.dropFirst()))
    switch command {
    case .generate(let seed):
        try generate(seed: seed)
    case .validate:
        exit(try validate() ? 0 : 1)
    case .train(let options):
        try await train(options)
    case .evaluate(let options):
        try await evaluate(options)
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(1)
}

// MARK: - Commands

/// Writes the synthetic train, validation and test splits. Examples the validator rejects are
/// reported and left out.
func generate(seed: UInt64) throws {
    let validator = ExampleValidator()
    var trainGenerator = ExampleGenerator(split: .train, seed: seed)
    var validGenerator = ExampleGenerator(split: .valid, seed: seed &+ 1)
    var testGenerator = ExampleGenerator(split: .test, seed: seed &+ 2)
    // Test first, so training and validation can leave its texts out.
    var test = testGenerator.generate()
    var train = trainGenerator.generate(excluding: Set(test.map(\.raw)))
    var valid = validGenerator.generate(excluding: Set((test + train).map(\.raw)))

    func keepValid(_ examples: inout [TrainingExample], split: DataSplit) throws {
        let rejected = examples.filter { !validator.problems(in: $0).isEmpty }
        for example in rejected.prefix(10) {
            print("rejected (\(split.rawValue)): \(validator.problems(in: example).joined(separator: "; ")): \(example.raw)")
        }
        examples.removeAll { !validator.problems(in: $0).isEmpty }
        try TrainingData.write(examples, to: Paths.generated(split))
        print("\(Paths.generated(split).relativePath): \(examples.count) examples, \(rejected.count) rejected")
    }
    try keepValid(&train, split: .train)
    try keepValid(&valid, split: .valid)
    try keepValid(&test, split: .test)
}

/// Checks every dataset file against ``ExampleValidator`` and that no test example appears in
/// training or validation. Returns whether everything passed.
func validate() throws -> Bool {
    let validator = ExampleValidator()
    var failures = 0
    for file in try Paths.allDataFiles() {
        let examples = try TrainingData.read(from: file)
        var fileFailures = 0
        for (index, example) in examples.enumerated() {
            let problems = validator.problems(in: example)
            guard !problems.isEmpty else { continue }
            fileFailures += 1
            print("\(file.relativePath):\(index + 1): \(problems.joined(separator: "; "))")
            print("    raw:    \(example.raw)")
            print("    target: \(example.target)")
        }
        print("\(file.relativePath): \(examples.count) examples, \(fileFailures) with problems")
        failures += fileFailures
    }

    let testRaws = Set(try Paths.testFiles().flatMap { try TrainingData.read(from: $0) }.map { EditDistance.normalize($0.raw) })
    for file in try Paths.trainingFiles() + [Paths.generated(.valid)] where FileManager.default.fileExists(atPath: file.path) {
        for (index, example) in try TrainingData.read(from: file).enumerated() where testRaws.contains(EditDistance.normalize(example.raw)) {
            print("\(file.relativePath):\(index + 1): also in the test data: \(example.raw)")
            failures += 1
        }
    }
    print(failures == 0 ? "All examples are valid." : "\(failures) problems.")
    return failures == 0
}

func train(_ options: TrainCommandOptions) async throws {
    let settings = AppSettings.defaults
    let modelID = settings.llmModel
    guard let revision = options.revision ?? CleanupModelLoader.cachedCommit(modelID: modelID) else {
        throw TrainError.noRevision(modelID)
    }
    guard try validate() else { throw TrainError.invalidData }

    let curated = try Paths.curatedFiles(.train).flatMap { try TrainingData.read(from: $0) }
    let generated = try TrainingData.read(from: Paths.generated(.train))
    let trainSet = generated + Array(repeating: curated, count: options.curatedRepeats).flatMap { $0 }
    let validSet = try TrainingData.read(from: Paths.generated(.valid))
    print("Training on \(generated.count) generated + \(curated.count) curated (x\(options.curatedRepeats)) examples; validating on \(validSet.count)")

    print("Loading \(modelID) at \(revision)")
    let container = try await CleanupModelLoader.loadContainer(modelID: modelID, revision: revision) { _ in }
    let started = Date()
    let report = try await AdapterTrainer.train(
        container: container,
        baseModel: modelID,
        baseRevision: revision,
        train: trainSet,
        valid: validSet,
        template: Prompt.adapted,
        contextLimit: settings.contextSegments,
        options: options.training,
        output: options.output
    ) { message in
        print(String(format: "[%6.0fs] ", Date().timeIntervalSince(started)) + message)
    }
    let reportURL = options.output.appending(component: "training-report.json")
    try writeJSON(report, to: reportURL)
    print(String(format: "Best validation loss %.4f at iteration %d; adapter in %@, report in %@",
                 report.bestValidationLoss, report.bestIteration, options.output.relativePath, reportURL.relativePath))
}

func evaluate(_ options: EvaluateCommandOptions) async throws {
    let settings = AppSettings.defaults
    let adapter: CleanupAdapter?
    switch options.adapter {
    case .bundled:
        adapter = CleanupAdapter.bundled()
        if adapter == nil { print("No bundled adapter: evaluating the base model") }
    case .directory(let directory):
        guard let loaded = try CleanupAdapter.load(from: directory) else { throw TrainError.noAdapter(directory.relativePath) }
        adapter = loaded
    case .none:
        adapter = nil
    }

    let files = options.data.isEmpty ? try Paths.testFiles() : options.data
    let examples = try files.flatMap { try TrainingData.read(from: $0) }
    print("Evaluating \(adapter.map { "the adapter in \($0.directory.relativePath)" } ?? "the base model") on \(examples.count) examples")

    MLXRuntime.configure(gpuCacheLimitMB: settings.gpuCacheLimitMB)
    let cleaner = MLXCleaner(configuration: .init(settings: settings, adapter: adapter))
    try await cleaner.load { _ in }
    if adapter != nil, await cleaner.activeAdapter == nil {
        throw TrainError.adapterNotApplied
    }

    let report = await AdapterEvaluator.evaluate(examples, with: cleaner, options: ExampleValidator.options) { print($0) }
    for miss in report.misses {
        print("MISS \(miss.category.rawValue)\(miss.fallbackReason.map { " (fell back: \($0))" } ?? "")")
        print("    raw:      \(miss.raw)")
        print("    expected: \(miss.expected)")
        print("    shown:    \(miss.shown)")
    }
    print(report.summary)
    if let reportURL = options.report {
        try writeJSON(report, to: reportURL)
        print("Report in \(reportURL.relativePath)")
    }
}

func writeJSON(_ value: some Encodable, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encoder.encode(value).write(to: url)
}

// MARK: - Files

/// The dataset layout under `Training/`, relative to the package directory.
enum Paths {
    static let root = URL(fileURLWithPath: "Training", isDirectory: true)
    static let curated = root.appending(component: "curated", directoryHint: .isDirectory)
    static let generated = root.appending(component: "generated", directoryHint: .isDirectory)
    static let defaultAdapterOutput = root.appending(path: "runs/adapter", directoryHint: .isDirectory)

    static func generated(_ split: DataSplit) -> URL {
        generated.appending(component: "\(split.rawValue).jsonl")
    }

    /// Hand-written examples: `curated/train` for training, `curated/test` for evaluation only.
    static func curatedFiles(_ split: DataSplit) throws -> [URL] {
        let directory = curated.appending(component: split.rawValue, directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func trainingFiles() throws -> [URL] {
        try curatedFiles(.train) + [generated(.train)]
    }

    static func testFiles() throws -> [URL] {
        try curatedFiles(.test) + [generated(.test)].filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func allDataFiles() throws -> [URL] {
        try curatedFiles(.train) + curatedFiles(.test)
            + DataSplit.allCases.map(generated).filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}

// MARK: - Arguments

struct TrainCommandOptions {
    var output = Paths.defaultAdapterOutput
    var revision: String?
    var curatedRepeats = 2
    var training = TrainingOptions()
}

struct EvaluateCommandOptions {
    enum AdapterChoice {
        case bundled
        case directory(URL)
        case none
    }

    var adapter = AdapterChoice.bundled
    var data: [URL] = []
    var report: URL?
}

enum Command {
    case generate(seed: UInt64)
    case validate
    case train(TrainCommandOptions)
    case evaluate(EvaluateCommandOptions)

    static func parse(_ arguments: [String]) throws -> Command {
        guard let name = arguments.first else { throw TrainError.usage("missing command") }
        var iterator = arguments.dropFirst().makeIterator()
        func value(_ flag: String) throws -> String {
            guard let value = iterator.next() else { throw TrainError.usage("\(flag) needs a value") }
            return value
        }
        func number<T: LosslessStringConvertible>(_ flag: String) throws -> T {
            let text = try value(flag)
            guard let number = T(text) else { throw TrainError.usage("\(flag): not a number: \(text)") }
            return number
        }

        switch name {
        case "generate":
            var seed: UInt64 = 1
            while let argument = iterator.next() {
                switch argument {
                case "--seed": seed = try number(argument)
                default: throw TrainError.usage("unknown argument \(argument)")
                }
            }
            return .generate(seed: seed)
        case "validate":
            if let argument = iterator.next() { throw TrainError.usage("unknown argument \(argument)") }
            return .validate
        case "train":
            var options = TrainCommandOptions()
            while let argument = iterator.next() {
                switch argument {
                case "--output": options.output = URL(fileURLWithPath: try value(argument), isDirectory: true)
                case "--revision": options.revision = try value(argument)
                case "--iterations": options.training.iterations = try number(argument)
                case "--batch-size": options.training.batchSize = try number(argument)
                case "--learning-rate": options.training.learningRate = try number(argument)
                case "--rank": options.training.rank = try number(argument)
                case "--scale": options.training.scale = try number(argument)
                case "--layers": options.training.layers = try number(argument)
                case "--curated-repeats": options.curatedRepeats = try number(argument)
                case "--seed": options.training.seed = try number(argument)
                default: throw TrainError.usage("unknown argument \(argument)")
                }
            }
            return .train(options)
        case "evaluate":
            var options = EvaluateCommandOptions()
            while let argument = iterator.next() {
                switch argument {
                case "--adapter": options.adapter = .directory(URL(fileURLWithPath: try value(argument), isDirectory: true))
                case "--no-adapter": options.adapter = .none
                case "--data": options.data.append(URL(fileURLWithPath: try value(argument)))
                case "--report": options.report = URL(fileURLWithPath: try value(argument))
                default: throw TrainError.usage("unknown argument \(argument)")
                }
            }
            return .evaluate(options)
        default:
            throw TrainError.usage("unknown command \(name)")
        }
    }
}

enum TrainError: LocalizedError {
    case usage(String)
    case noRevision(String)
    case invalidData
    case noAdapter(String)
    case adapterNotApplied

    var errorDescription: String? {
        switch self {
        case .usage(let detail):
            """
            \(detail)
            usage: Train generate [--seed <n>]
                   Train validate
                   Train train [--output <dir>] [--revision <commit>] [--iterations <n>] [--batch-size <n>]
                               [--learning-rate <x>] [--rank <n>] [--scale <x>] [--layers <n>]
                               [--curated-repeats <n>] [--seed <n>]
                   Train evaluate [--adapter <dir> | --no-adapter] [--data <file.jsonl>]... [--report <file>]
            """
        case .noRevision(let model):
            "\(model) is not in the Hugging Face cache. Pass --revision <commit>, or run the model tests once to download it."
        case .invalidData:
            "The dataset has problems (listed above). Fix them before training."
        case .noAdapter(let path):
            "No adapter weights in \(path)."
        case .adapterNotApplied:
            "The cleanup model fell back to running without the adapter; see the Cleanup log."
        }
    }
}
