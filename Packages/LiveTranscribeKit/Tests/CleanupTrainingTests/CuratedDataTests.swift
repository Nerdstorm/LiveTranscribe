import CleanupTraining
import Foundation
import Shared
import Testing

/// The hand-written examples in `Training/curated`: `train` is trained on, `test` is held out.
@Suite("Curated training data")
struct CuratedDataTests {
    private static let curated = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appending(path: "../../Training/curated")
        .standardizedFileURL

    private static func files(_ split: String) throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(at: curated.appending(component: split), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jsonl" }
    }

    private static func examples(_ split: String) throws -> [TrainingExample] {
        try files(split).flatMap { try TrainingData.read(from: $0) }
    }

    @Test("Every curated example passes the validator", arguments: ["train", "test"])
    func everyExampleIsValid(split: String) throws {
        let validator = ExampleValidator()
        let examples = try Self.examples(split)
        #expect(!examples.isEmpty)
        for example in examples {
            let problems = validator.problems(in: example)
            #expect(problems.isEmpty, "\(example.source): \(example.raw) → \(example.target): \(problems)")
        }
    }

    @Test func everyCategoryIsCoveredInBothSplits() throws {
        for split in ["train", "test"] {
            let categories = Set(try Self.examples(split).map(\.category))
            #expect(categories == Set(TrainingExample.Category.allCases), "\(split) covers \(categories)")
        }
    }

    @Test func heldOutExamplesNeverAppearInTraining() throws {
        var generator = ExampleGenerator(split: .train, seed: 1)
        let training = try Self.examples("train") + generator.generate()
        let trainingTexts = Set(training.map { EditDistance.normalize($0.raw) })
        let leaked = try Self.examples("test").filter { trainingTexts.contains(EditDistance.normalize($0.raw)) }
        #expect(leaked.isEmpty, "\(leaked.map(\.raw))")
    }
}
