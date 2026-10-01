@testable import Cleanup
@testable import CleanupTraining
import Foundation
import Shared
import Testing

/// `Training/eval/layout.jsonl`: hand-written cases for Deep's lists, email bodies, placeholders and
/// mentions, which are never trained on. Each target must be an answer Deep's own check lets
/// through, or the case could never be scored right.
@Suite("Layout eval cases")
struct EvalLayoutTests {
    private static let file = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // CleanupTrainingTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // LiveTranscribeKit
        .appendingPathComponent("Training/eval/layout.jsonl")

    private func cases() throws -> [EvalCase] {
        try EvalCase.read(from: Self.file)
    }

    @Test func thereAreCasesOfEveryKind() throws {
        let cases = try cases()
        #expect(cases.count >= 200)
        #expect(Set(cases.map(\.id)).count == cases.count, "ids are unique")
        let expected: [String: Int] = ["list-two": 30, "list-many": 40, "series": 35, "email-body": 35, "placeholder": 40, "mention": 20]
        for (category, least) in expected {
            #expect(cases.filter { $0.category == category }.count >= least, "\(category)")
        }
        #expect(Set(cases.map(\.category)).isSubset(of: Set(expected.keys)))
        #expect(
            cases.filter { $0.letterBody && $0.category != "placeholder" }.allSatisfy { $0.multiline },
            "a body is laid out in a field that takes several lines"
        )
    }

    @Test func everyTargetPassesDeepsCheck() throws {
        let guardian = OutputGuard()
        for evalCase in try cases() {
            let input = CleanupExecutor.deterministicCleanup(of: evalCase.raw, level: .deep)
            let options = evalCase.options(level: .deep)
            let verdict = guardian.review(raw: input, outcome: .completed(evalCase.target), options: options)
            #expect(verdict == .accepted(evalCase.target), "\(evalCase.id): \(verdict) for \(evalCase.target.debugDescription)")
            for alternative in evalCase.alternatives {
                #expect(guardian.review(raw: input, outcome: .completed(alternative), options: options) == .accepted(alternative), "\(evalCase.id) alternative")
            }
        }
    }

    @Test func keepAndAvoidAgreeWithTheTarget() throws {
        for evalCase in try cases() {
            let target = " \(EditDistance.normalize(evalCase.target)) "
            for phrase in evalCase.keep {
                #expect(!EditDistance.normalize(phrase).isEmpty, "\(evalCase.id) keeps a phrase with no words in it")
                #expect(target.contains(" \(EditDistance.normalize(phrase)) "), "\(evalCase.id) keeps \(phrase)")
            }
            for phrase in evalCase.avoid {
                #expect(!EditDistance.normalize(phrase).isEmpty, "\(evalCase.id) avoids a phrase with no words in it")
                #expect(!target.contains(" \(EditDistance.normalize(phrase)) "), "\(evalCase.id) avoids \(phrase)")
            }
        }
    }

    @Test func aPhraseWithNoWordsDoesNotMakeAnAnswerChangeTheMeaning() {
        let evalCase = EvalCase(id: "x", category: "list-many", raw: "a b", target: "A\nB", multiline: true, avoid: ["\n"])
        #expect(evalCase.judge(shown: "A, then B.", fellBack: false, input: "a b", level: .deep) == .different)
    }

    @Test func placeholdersComeBackOnceEach() throws {
        for evalCase in try cases() {
            let tokens = PlaceholderToken.tokens(in: evalCase.raw)
            #expect(PlaceholderToken.tokens(in: evalCase.target) == tokens, "\(evalCase.id)")
            #expect(Set(tokens).count == tokens.count, "\(evalCase.id) repeats a token")
        }
    }

    @Test func aListOfTwoIsLaidOutOnlyAfterAColon() throws {
        for evalCase in try cases() where evalCase.target.contains("\n- ") {
            let items = SelfRepair.bulletedLists(in: evalCase.target).map(\.items.count)
            #expect(items.allSatisfy { $0 >= 3 } || evalCase.raw.contains(":"), "\(evalCase.id)")
            #expect(evalCase.multiline, "\(evalCase.id)")
        }
    }
}
