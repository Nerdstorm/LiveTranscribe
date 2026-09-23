@testable import CleanupTraining
import Testing

@Suite("ExampleValidator")
struct ExampleValidatorTests {
    private let validator = ExampleValidator()

    private func problems(_ category: TrainingExample.Category, _ raw: String, _ target: String, context: [String] = []) -> [String] {
        validator.problems(in: TrainingExample(category: category, context: context, raw: raw, target: target, source: "test"))
    }

    @Test func acceptsWellFormedExamplesOfEveryCategory() {
        #expect(problems(.correction, "we need three sorry four more servers", "We need four more servers.").isEmpty)
        #expect(problems(.control, "sorry i'm late the train was delayed", "Sorry I'm late, the train was delayed.").isEmpty)
        #expect(problems(.cleanup, "the the build is green again", "The build is green again.").isEmpty)
        #expect(problems(.boundary, "sorry thursday", "Sorry, Thursday.", context: ["Let's meet on Tuesday."]).isEmpty)
    }

    @Test func aCorrectionMustDropItsCue() {
        #expect(!problems(.correction, "we need three sorry four more servers", "We need three, sorry, four more servers.").isEmpty)
    }

    @Test func aCorrectionTheGuardRejectsIsRefused() {
        // Keeps the retracted words instead of the correction.
        #expect(problems(.correction, "we need three sorry four more servers", "We need three more servers.")
            .contains("the output guard rejects the target"))
    }

    @Test func controlsAndBoundariesMustKeepEveryWord() {
        #expect(!problems(.control, "sorry i'm late the train was delayed", "I'm late, the train was delayed.").isEmpty)
        #expect(!problems(.boundary, "sorry thursday", "Thursday.", context: ["Let's meet on Tuesday."]).isEmpty)
    }

    @Test func controlsAndBoundariesNeedACue() {
        #expect(problems(.control, "the train was delayed", "The train was delayed.").contains("must contain a correction cue"))
    }

    @Test func cleanupMayOnlyDropADoubledWord() {
        #expect(!problems(.cleanup, "the build is green again", "The build is green.").isEmpty)
        #expect(problems(.cleanup, "sorry the build is green", "Sorry, the build is green.")
            .contains("cleanup examples must not contain a correction cue"))
    }

    @Test func rejectsBlankContextAndOverlongText() {
        #expect(problems(.cleanup, "the build is green", "The build is green.", context: ["  "]).contains("blank context line"))
        let long = Array(repeating: "word", count: ExampleValidator.maxWords + 1).joined(separator: " ")
        #expect(!problems(.cleanup, long, long).isEmpty)
    }

    @Test func doubledWordsCollapseToOne() {
        #expect(ExampleValidator.withoutDoubledWords(["the", "the", "build", "is", "is", "green"]) == ["the", "build", "is", "green"])
    }
}
