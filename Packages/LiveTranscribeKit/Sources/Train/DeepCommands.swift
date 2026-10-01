import Cleanup
import CleanupTraining
import Foundation
import Shared

// The Deep adapter's commands: its synthetic data, its checks and its training. See
// Training/README.md.

enum DeepPaths {
    static func generated(_ split: DataSplit) -> URL {
        Paths.generated.appending(component: "deep-\(split.rawValue).jsonl")
    }

    /// Hand-written cases that measure Deep and are never trained on: `deep.jsonl` (corrections,
    /// grammar, layout) and `layout.jsonl` (lists, email bodies, placeholders, mentions).
    static let evalDirectory = Paths.root.appending(path: "eval", directoryHint: .isDirectory)
    static let eval = evalDirectory.appending(path: "deep.jsonl")
    static let layoutEval = evalDirectory.appending(path: "layout.jsonl")
    static let defaultAdapterOutput = Paths.root.appending(path: "runs/deep-adapter", directoryHint: .isDirectory)
}

/// Writes Deep's synthetic train, validation and test splits, leaving out what the validator
/// rejects, and reports how much of each category that was. Training and validation also get
/// some of Medium's examples (``DeepExampleGenerator/mediumCounts(for:)``), a third of them in a
/// field that takes several lines.
func generateDeep(seed: UInt64) throws {
    let validator = DeepExampleValidator()
    let evalRaws = try heldOutRaws()
    var testGenerator = DeepExampleGenerator(split: .test, seed: seed &+ 2)
    var trainGenerator = DeepExampleGenerator(split: .train, seed: seed)
    var validGenerator = DeepExampleGenerator(split: .valid, seed: seed &+ 1)
    // Test first, so training and validation can leave its texts out, and the eval cases too.
    let test = testGenerator.generate(excluding: evalRaws)
    let deepTrain = trainGenerator.generate(excluding: evalRaws.union(test.map(\.raw)))
    let deepValid = validGenerator.generate(excluding: evalRaws.union((test + deepTrain).map(\.raw)))
    func medium(_ split: DataSplit, seed: UInt64, excluding: Set<String>) -> [DeepExample] {
        var generator = ExampleGenerator(split: split, seed: seed)
        return generator.generate(counts: DeepExampleGenerator.mediumCounts(for: split), excluding: excluding).enumerated().map {
            DeepExample(medium: $0.element, multiline: $0.offset % 3 == 0)
        }
    }
    let excluded = evalRaws.union(test.map(\.raw)).union(try mediumTestRaws())
    let mediumTrain = medium(.train, seed: seed &+ 3, excluding: excluded.union((deepTrain + deepValid).map(\.raw)))
    let mediumValid = medium(.valid, seed: seed &+ 4, excluding: excluded.union((deepTrain + deepValid + mediumTrain).map(\.raw)))
    let train = deepTrain + mediumTrain
    let valid = deepValid + mediumValid

    for (split, examples) in [(DataSplit.train, train), (.valid, valid), (.test, test)] {
        var kept: [DeepExample] = []
        var rejected: [DeepExample.Category: Int] = [:]
        var shown = 0
        for example in examples {
            let problems = validator.problems(in: example)
            if problems.isEmpty {
                kept.append(example)
                continue
            }
            rejected[example.category, default: 0] += 1
            if shown < 12 {
                shown += 1
                print("rejected (\(split.rawValue), \(example.category.rawValue)): \(problems.joined(separator: "; "))")
                print("    raw:    \(example.raw)")
                print("    target: \(example.target.replacingOccurrences(of: "\n", with: "⏎"))")
            }
        }
        try DeepExample.write(kept, to: DeepPaths.generated(split))
        let counts = DeepExample.Category.allCases.map { category in
            "\(category.rawValue) \(kept.filter { $0.category == category }.count) (-\(rejected[category] ?? 0))"
        }
        let fromMedium = kept.filter { $0.source.hasPrefix("medium-") }.count
        print("\(DeepPaths.generated(split).relativePath): \(kept.count) examples, \(fromMedium) of them Medium's: \(counts.joined(separator: ", "))")
    }
}

/// Checks Deep's generated files against ``DeepExampleValidator``, and that no test or eval text
/// appears in training or validation. Returns whether everything passed.
func validateDeep() throws -> Bool {
    let validator = DeepExampleValidator()
    var failures = 0
    for split in DataSplit.allCases {
        let file = DeepPaths.generated(split)
        guard FileManager.default.fileExists(atPath: file.path) else {
            print("\(file.relativePath): missing; run Train generate --deep")
            failures += 1
            continue
        }
        let examples = try DeepExample.read(from: file)
        var fileFailures = 0
        for (index, example) in examples.enumerated() {
            let problems = validator.problems(in: example)
            guard !problems.isEmpty else { continue }
            fileFailures += 1
            print("\(file.relativePath):\(index + 1): \(problems.joined(separator: "; "))")
        }
        print("\(file.relativePath): \(examples.count) examples, \(fileFailures) with problems")
        failures += fileFailures
    }
    let heldOut = try heldOutRaws().union(try mediumTestRaws()).union(
        (try? DeepExample.read(from: DeepPaths.generated(.test)))?.map { EditDistance.normalize($0.raw) } ?? []
    )
    for split in [DataSplit.train, .valid] where FileManager.default.fileExists(atPath: DeepPaths.generated(split).path) {
        for (index, example) in try DeepExample.read(from: DeepPaths.generated(split)).enumerated()
        where heldOut.contains(EditDistance.normalize(example.raw)) {
            print("\(DeepPaths.generated(split).relativePath):\(index + 1): also held out for testing: \(example.raw)")
            failures += 1
        }
    }
    print(failures == 0 ? "All Deep examples are valid." : "\(failures) problems.")
    return failures == 0
}

/// Trains Deep's adapter on its generated splits, with the prompts the app sends at Deep.
func trainDeep(_ options: TrainCommandOptions) async throws {
    let settings = AppSettings.defaults
    let modelID = settings.llmModel
    guard let revision = options.revision ?? CleanupModelLoader.cachedCommit(modelID: modelID) else {
        throw TrainError.noRevision(modelID)
    }
    guard try validateDeep() else { throw TrainError.invalidData }

    let executor = CleanupExecutor(
        contextLimit: settings.contextSegments,
        timeoutSeconds: settings.cleanupTimeoutSeconds,
        prompts: PromptBuilder(adapted: true),
        deep: .shipped
    )
    let train = try DeepExample.read(from: DeepPaths.generated(.train)).map { TrainingItem($0, executor: executor) }
    let valid = try DeepExample.read(from: DeepPaths.generated(.valid)).map { TrainingItem($0, executor: executor) }
    print("Training Deep's adapter on \(train.count) examples; validating on \(valid.count)")

    print("Loading \(modelID) at \(revision)")
    let container = try await CleanupModelLoader.loadContainer(modelID: modelID, revision: revision) { _ in }
    let started = Date()
    let report = try await AdapterTrainer.train(
        container: container,
        baseModel: modelID,
        baseRevision: revision,
        train: train,
        valid: valid,
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

/// The raw texts of the hand-written eval cases (every `.jsonl` file in `eval/`), normalized, which
/// no generated example may repeat.
private func heldOutRaws() throws -> Set<String> {
    // An unreadable folder is an error: with no cases held out, generation would train on them.
    let files = try FileManager.default.contentsOfDirectory(at: DeepPaths.evalDirectory, includingPropertiesForKeys: nil)
    return Set(try files.filter { $0.pathExtension == "jsonl" }.flatMap { try EvalCase.read(from: $0) }.map { EditDistance.normalize($0.raw) })
}

/// The raw texts of Medium's test cases, normalized, which measure Deep against Medium and so
/// are never trained on either.
private func mediumTestRaws() throws -> Set<String> {
    Set(try Paths.testFiles().flatMap { try EvalCase.read(from: $0) }.map { EditDistance.normalize($0.raw) })
}
