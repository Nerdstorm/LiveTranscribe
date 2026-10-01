import Cleanup
@testable import CleanupTraining
import Foundation
import Shared
import Testing

/// The examples of Deep's layout categories: lists, series, email bodies, placeholders, mentions.
@Suite("Deep layout examples")
struct DeepLayoutGeneratorTests {
    private static let layoutCategories: [DeepExample.Category] = [.listTwo, .listMany, .series, .body, .placeholder, .mention]

    /// Each split is generated once: it takes a while.
    private static let generated: [DataSplit: [DeepExample]] = Dictionary(
        uniqueKeysWithValues: DataSplit.allCases.map { split in
            var generator = DeepExampleGenerator(split: split, seed: 1)
            return (split, generator.generate().filter { layoutCategories.contains($0.category) })
        }
    )

    private func examples(_ split: DataSplit) -> [DeepExample] {
        Self.generated[split] ?? []
    }

    private let executor = CleanupExecutor(contextLimit: 3, timeoutSeconds: 30, prompts: PromptBuilder(adapted: true), deep: .shipped)

    @Test("Every layout example passes the validator", arguments: DataSplit.allCases)
    func everyExampleIsValid(split: DataSplit) {
        let validator = DeepExampleValidator()
        let invalid = examples(split).filter { !validator.problems(in: $0).isEmpty }
        #expect(invalid.isEmpty, "\(invalid.prefix(3).map { "\($0.raw) → \($0.target)" })")
    }

    @Test func aTwoItemListIsLaidOutOnlyWhenTheSpeakerSetItOffWithAColon() {
        let laidOut = examples(.train).filter { $0.category == .listTwo && $0.target.contains("\n") }
        #expect(laidOut.count > 50)
        for example in laidOut {
            #expect(example.raw.contains(":"), "\(example.raw)")
            #expect(example.multiline, "\(example.raw)")
        }
    }

    @Test func aListIsNeverLaidOutInAOneLineField() {
        for example in examples(.train) where !example.multiline {
            #expect(!example.target.contains("\n"), "\(example.raw)")
        }
    }

    @Test func aBodyIsMarkedAsAnEmailsAndIsInAFieldThatTakesLines() {
        let bodies = examples(.train).filter { $0.category == .body }
        #expect(!bodies.isEmpty)
        #expect(bodies.allSatisfy { $0.letterBody && $0.multiline })
        #expect(
            examples(.train).filter { $0.letterBody && $0.category != .body && $0.category != .placeholder }.isEmpty,
            "only bodies and placeholders say the text is an email's"
        )
    }

    @Test func aBodyHasNoGreetingOrSignOff() {
        for example in examples(.train) where example.category == .body {
            let first = example.target.split(separator: "\n").first.map(String.init) ?? ""
            #expect(!first.lowercased().hasPrefix("hi ") && !first.lowercased().hasPrefix("dear "), "\(example.target)")
            #expect(!example.target.lowercased().contains("kind regards"), "\(example.target)")
        }
    }

    @Test func placeholdersComeBackOnceEach() {
        let withTokens = examples(.train).filter { $0.category == .placeholder }
        #expect(withTokens.count == 800)
        for example in withTokens {
            let tokens = PlaceholderToken.tokens(in: example.raw)
            #expect(!tokens.isEmpty, "\(example.raw)")
            #expect(PlaceholderToken.tokens(in: example.target) == tokens, "\(example.raw) → \(example.target)")
        }
    }

    @Test func theModelIsAskedWithTheWordsItSeesInPlaceOfTheTokens() throws {
        let example = try #require(examples(.train).first { $0.category == .placeholder })
        let item = TrainingItem(example, executor: executor)
        let user = item.request.messages.last?.content ?? ""
        #expect(!user.contains("⟦") && !item.target.contains("⟦"))
        #expect(item.target.contains("S1"))
        #expect(user.contains("S1"))
    }

    @Test func theLetterBodyRuleIsInThePromptOnlyForABody() throws {
        let body = try #require(examples(.train).first { $0.category == .body })
        let series = try #require(examples(.train).first { $0.category == .series && $0.multiline && !$0.letterBody })
        func system(_ example: DeepExample) -> String {
            TrainingItem(example, executor: executor).request.messages.first?.content ?? ""
        }
        #expect(system(body).contains("body of an email"))
        #expect(!system(series).contains("body of an email"))
    }

    @Test func noExampleTextIsInBothTrainingAndTest() {
        func fixed(_ example: DeepExample) -> String { EditDistance.normalize(example.raw) }
        let train = Set(examples(.train).map(fixed))
        let test = examples(.test).map(fixed)
        #expect(test.allSatisfy { !train.contains($0) })
    }
}
