@testable import CleanupTraining
import Shared
import Testing

@Suite("ExampleGenerator")
struct ExampleGeneratorTests {
    private func generate(_ split: DataSplit, seed: UInt64 = 1) -> [TrainingExample] {
        var generator = ExampleGenerator(split: split, seed: seed)
        return generator.generate()
    }

    @Test func theSameSeedGivesTheSameData() {
        #expect(generate(.valid, seed: 7) == generate(.valid, seed: 7))
        #expect(generate(.valid, seed: 7) != generate(.valid, seed: 8))
    }

    @Test("Each split has the planned size and mix", arguments: DataSplit.allCases)
    func splitSizes(split: DataSplit) {
        let examples = generate(split)
        let counts = ExampleGenerator.counts(for: split)
        #expect(examples.count == counts.total)
        #expect(examples.filter { $0.category == .correction }.count == counts.correction + counts.scratch)
        #expect(examples.filter { $0.category == .control }.count == counts.control)
        #expect(examples.filter { $0.category == .cleanup }.count == counts.cleanup)
        #expect(examples.filter { $0.category == .boundary }.count == counts.boundary)
        #expect(Set(examples.map(\.raw)).count == examples.count, "raw texts are unique")
    }

    @Test("Every generated example passes the validator", arguments: DataSplit.allCases)
    func everyExampleIsValid(split: DataSplit) {
        let validator = ExampleValidator()
        let invalid = generate(split).filter { !validator.problems(in: $0).isEmpty }
        #expect(invalid.isEmpty, "\(invalid.prefix(3).map { "\($0.raw) → \($0.target): \(validator.problems(in: $0))" })")
    }

    @Test func validationNeverRepeatsATrainingText() {
        let train = generate(.train)
        var generator = ExampleGenerator(split: .valid, seed: 2)
        let valid = generator.generate(excluding: Set(train.map(\.raw)))
        #expect(Set(valid.map(\.raw)).isDisjoint(with: train.map(\.raw)))
    }

    @Test func excludedTextsAreSkippedIgnoringCasingAndPunctuation() {
        let test = generate(.test)
        var generator = ExampleGenerator(split: .train, seed: 1)
        let train = generator.generate(excluding: Set(test.map(\.raw)))
        let testTexts = Set(test.map { EditDistance.normalize($0.raw) })
        #expect(train.allSatisfy { !testTexts.contains(EditDistance.normalize($0.raw)) })
        #expect(train.count == ExampleGenerator.counts(for: .train).total)
    }

    @Test func theTestSplitSharesNoSentenceWithTraining() {
        let train = Set(generate(.train).map { EditDistance.normalize($0.target) })
        let test = generate(.test).filter { $0.category != .boundary }.map { EditDistance.normalize($0.target) }
        #expect(train.isDisjoint(with: test))
    }

    @Test func testVocabularyIsHeldOutFromTraining() {
        // Weekdays and months are closed sets, so they are shared on purpose.
        for slot in Slot.allCases where slot != .weekday && slot != .month {
            let pools = Pools.all[slot]!
            #expect(Set(pools.train).isDisjoint(with: pools.test), "\(slot) values overlap")
        }
    }

    @Test func aboutAThirdOfExamplesCarryContext() {
        let examples = generate(.train).filter { $0.category != .boundary }
        let share = Double(examples.filter { !$0.context.isEmpty }.count) / Double(examples.count)
        #expect(share > 0.25 && share < 0.35)
    }
}
