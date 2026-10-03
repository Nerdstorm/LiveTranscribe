import Cleanup
@testable import CleanupTraining
import Foundation
import Shared
import Testing

@Suite("DeepExampleGenerator")
struct DeepExampleGeneratorTests {
    private func generate(_ split: DataSplit, seed: UInt64 = 1) -> [DeepExample] {
        var generator = DeepExampleGenerator(split: split, seed: seed)
        return generator.generate()
    }

    @Test func theSameSeedGivesTheSameData() {
        #expect(generate(.valid, seed: 7) == generate(.valid, seed: 7))
        #expect(generate(.valid, seed: 7) != generate(.valid, seed: 8))
    }

    @Test("Each split has the planned mix", arguments: DataSplit.allCases)
    func splitSizes(split: DataSplit) {
        let examples = generate(split)
        for (category, count) in DeepExampleGenerator.counts(for: split) {
            #expect(examples.filter { $0.category == category }.count == count, "\(category)")
        }
        #expect(Set(examples.map { "\($0.multiline) \(EditDistance.normalize($0.raw))" }).count == examples.count, "raw texts are unique")
    }

    /// The validator drops the rest: a correction of something no check can tell the phrase is
    /// about ("the auth service. Sorry, the cache.") is left for Medium's pass.
    @Test("Nearly every generated example passes the validator", arguments: DataSplit.allCases)
    func nearlyEveryExampleIsValid(split: DataSplit) {
        let validator = DeepExampleValidator()
        let examples = generate(split)
        let invalid = examples.filter { !validator.problems(in: $0).isEmpty }
        #expect(Double(invalid.count) < Double(examples.count) * 0.03, "\(invalid.prefix(3).map { "\($0.raw) → \($0.target)" })")
        #expect(invalid.allSatisfy { [.crossSentence, .sameSentence, .recognition].contains($0.category) })
    }

    @Test func testNamesAndFramesNeverAppearInTraining() {
        let train = generate(.train).map(\.raw).joined(separator: "\n").lowercased()
        for name in Pools.values(.name, split: .test) {
            #expect(!train.contains(" \(name.lowercased()) "), "\(name)")
        }
        for frame in DeepFrames.timeKeptTest {
            // The frame's longest fixed stretch, which only it says.
            let fixed = frame.text.components(separatedBy: "{X}").map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) }
            let longest = fixed.max { $0.count < $1.count } ?? ""
            #expect(!train.contains(longest), "\(frame.text)")
        }
    }

    @Test func aCorrectionOfSomethingElseKeepsTheTimeSaid() {
        let examples = generate(.train)
        let kept = examples.filter { example in
            [.sameSentence, .crossSentence].contains(example.category) && example.target.contains("next week")
                && !example.target.contains("after next")
        }
        let garbled = examples.filter { $0.target.contains("the week after next") }
        #expect(kept.count > 20, "the adapter sees that a time outside the correction stays")
        #expect(!garbled.isEmpty, "and still reads a garbled one as meant")
    }

    @Test func trainingNamesIncludeOnesTheAdapterMustNotFix() {
        #expect(DeepPools.names(split: .train).count > Pools.values(.name, split: .train).count + 40)
        #expect(Set(DeepPools.names(split: .train)).isDisjoint(with: DeepPools.names(split: .test)))
        #expect(DeepPools.names(split: .test) == Pools.values(.name, split: .test))
    }

    @Test func mediumsExamplesGoIntoTrainingAndValidationOnly() {
        #expect(DeepExampleGenerator.mediumCounts(for: .train).total > 1_000)
        #expect(DeepExampleGenerator.mediumCounts(for: .valid).total > 0)
        #expect(DeepExampleGenerator.mediumCounts(for: .test).total == 0, "Medium's own test split measures that")
    }

    @Test("A Medium example keeps its target in the category that judges it the same way", arguments: [
        (TrainingExample.Category.correction, DeepExample.Category.sameSentence),
        (.control, .control),
        (.boundary, .control),
        (.cleanup, .unchanged),
    ])
    func mediumExampleCategories(medium: TrainingExample.Category, deep: DeepExample.Category) {
        let example = TrainingExample(category: medium, context: ["Earlier."], raw: "raw text", target: "Raw text.", source: "generated")
        let converted = DeepExample(medium: example, multiline: true)
        #expect(converted.category == deep)
        #expect(converted == DeepExample(
            category: deep, context: ["Earlier."], raw: "raw text", target: "Raw text.", multiline: true, source: "medium-generated"
        ))
    }
}

@Suite("DeepExampleValidator")
struct DeepExampleValidatorTests {
    private let validator = DeepExampleValidator()

    private func example(
        _ category: DeepExample.Category, _ raw: String, _ target: String, multiline: Bool = false
    ) -> DeepExample {
        DeepExample(category: category, raw: raw, target: target, multiline: multiline, source: "test")
    }

    @Test func acceptsAnExampleTheGuardAndItsCategoryAllow() {
        #expect(validator.problems(in: example(.crossSentence, "The demo is on Tuesday. Sorry, Wednesday.", "The demo is on Wednesday.")).isEmpty)
        #expect(validator.problems(in: example(.control, "Sorry I'm late.", "Sorry, I'm late.")).isEmpty)
        #expect(validator.problems(in: example(.grammar, "He go to the gym.", "He goes to the gym.")).isEmpty)
        // A common word speech-to-text wrote as a name is fixed by its capital alone.
        #expect(validator.problems(in: example(.recognition, "We left at Dawn to beat the traffic.", "We left at dawn to beat the traffic.")).isEmpty)
        #expect(validator.problems(in: example(.layout, "I need milk, eggs and bread.", "I need:\n- Milk\n- Eggs\n- Bread", multiline: true)).isEmpty)
    }

    @Test func rejectsATargetTheGuardWouldTurnDown() {
        let invented = example(.crossSentence, "The demo is on Tuesday. Sorry, Wednesday.", "The demo is on Wednesday at noon.")
        #expect(validator.problems(in: invented).contains("Deep's output guard rejects the target"))
    }

    @Test func rejectsATargetThatChangesTheTextOutsideItsCategory() {
        #expect(validator.problems(in: example(.crossSentence, "It works. Sorry, it's fast.", "It works. Sorry, it's fast.")).contains("a correction must take its cue out"))
        #expect(validator.problems(in: example(.control, "It works.", "It works.")).contains("must contain a correction cue"))
        #expect(validator.problems(in: example(.grammar, "He goes to the gym.", "He goes to the gym.")).contains("must fix a word"))
        #expect(validator.problems(in: example(.recognition, "we left at dawn. Then we ate.", "We left at dawn. then we ate.")).contains("must fix a word"))
        #expect(validator.problems(in: example(.grammar, "We left at Dawn to beat the traffic.", "We left at dawn to beat the traffic.")).contains("must fix a word"))
        #expect(validator.problems(in: example(.layout, "I need milk, eggs and bread.", "I need milk, eggs and bread.", multiline: true))
            .contains("must lay the text out in a field that takes several lines"))
        #expect(validator.problems(in: example(.oneLine, "I need milk, eggs and bread.", "I need:\n- Milk\n- Eggs\n- Bread"))
            .contains("must stay on one line in a one-line field"))
    }
}

@Suite("CleanupMeasurement")
struct CleanupMeasurementTests {
    private let deepCase = EvalCase(
        id: "kirk",
        category: "acceptance",
        raw: "I don't think he checked whether the release is tomorrow. No, sorry, the after tomorrow.",
        target: "I don't think he checked whether the release is the day after tomorrow.",
        keep: ["don't", "day after tomorrow"],
        avoid: ["answer"]
    )

    @Test func judgesWhatWouldBeShown() {
        let input = deepCase.raw
        #expect(deepCase.judge(shown: "i don't think he checked whether the release is the day after tomorrow", fellBack: false, input: input, level: .deep) == .right)
        #expect(deepCase.judge(shown: input, fellBack: true, input: input, level: .deep) == .fellBack)
        #expect(deepCase.judge(shown: input, fellBack: false, input: input, level: .deep) == .unchanged)
        #expect(deepCase.judge(shown: "I think he checked whether the release is the day after tomorrow.", fellBack: false, input: input, level: .deep) == .changedMeaning)
        #expect(deepCase.judge(shown: "I don't think he would answer whether the release is the day after tomorrow.", fellBack: false, input: input, level: .deep) == .changedMeaning)
        #expect(deepCase.judge(shown: "I don't think he answered whether the release is the day after tomorrow.", fellBack: false, input: input, level: .deep) == .different,
                "a word to avoid is matched whole, so a case lists its other forms")
        #expect(deepCase.judge(shown: "I don't think he checked if the release is the day after tomorrow.", fellBack: false, input: input, level: .deep) == .different)
    }

    @Test func aLaidOutCaseMustKeepItsLines() {
        let list = EvalCase(id: "list", category: "layout", raw: "I need milk and eggs.", target: "I need:\n- Milk\n- Eggs", multiline: true)
        #expect(list.judge(shown: "I need:\n- Milk\n- Eggs", fellBack: false, input: list.raw, level: .deep) == .right)
        #expect(list.judge(shown: "I need: milk, eggs", fellBack: false, input: list.raw, level: .deep) == .different)
    }

    /// Another runtime follows the file, so a request names the adapter the Mac would run it with.
    @Test func requestsNameTheAdapterTheyRunWith() async {
        let executor = CleanupExecutor(contextLimit: 3, timeoutSeconds: 30, prompts: PromptBuilder(adapted: false), deep: .shipped)
        let correction = EvalCase(id: "jane", category: "correction", raw: "send it to john i mean jane", target: "Send it to Jane.")
        let strict = await CleanupMeasurement.requests([correction], executor: executor, level: .medium, adapters: [])
        #expect(strict.map(\.adapter) == [.off])
        let adapted = await CleanupMeasurement.requests([correction], executor: executor, level: .medium, adapters: [.medium, .deep])
        #expect(adapted.map(\.adapter) == [.medium])
        let deepWithoutItsOwn = await CleanupMeasurement.requests([deepCase], executor: executor, level: .deep, adapters: [.medium])
        #expect(deepWithoutItsOwn.map(\.adapter) == [.medium])
    }

    @Test func replayScoresRecordedOutputsThroughTheGuard() async {
        let executor = CleanupExecutor(contextLimit: 3, timeoutSeconds: 30, prompts: PromptBuilder(adapted: true), deep: .shipped)
        let report = await CleanupMeasurement.replay(
            [deepCase],
            outputs: ["kirk": "I don't think he checked whether the release is the day after tomorrow."],
            executor: executor,
            level: .deep,
            configuration: "replay"
        )
        #expect(report.results.map(\.verdict) == [.right])

        // Medium's pass after a rejected repair has no recorded output, so the case falls back.
        let rejected = await CleanupMeasurement.replay(
            [deepCase],
            outputs: ["kirk": "I don't think he answered whether the release is the day after tomorrow."],
            executor: executor,
            level: .deep,
            configuration: "replay"
        )
        #expect(rejected.results.map(\.verdict) == [.fellBack])
    }
}
