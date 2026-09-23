import Cleanup
import Testing

@Suite("Prompt")
struct PromptTests {
    @Test func contextIsTruncatedToTheMostRecentSegments() {
        let context = ["one.", "two.", "three.", "four.", "five."]
        #expect(Prompt.contextWindow(context, limit: 3) == ["three.", "four.", "five."])
        #expect(Prompt.contextWindow(context, limit: 10) == context)
        #expect(Prompt.contextWindow(context, limit: 0).isEmpty)
    }

    @Test func blankContextSegmentsAreSkipped() {
        #expect(Prompt.contextWindow(["a.", "  ", "", "b."], limit: 3) == ["a.", "b."])
    }

    private let template = PromptTemplate(
        system: "Fix the TEXT.",
        examples: [.init(text: "example in", cleaned: "Example out.")]
    )

    @Test func examplesThenContextBecomeAnsweredTurnsBeforeTheText() {
        let request = Prompt.request(
            for: "the text to fix",
            context: ["Earlier one.", "Earlier two."],
            contextLimit: 1,
            template: template
        )
        #expect(request.messages == [
            .init(role: .system, content: "Fix the TEXT."),
            .init(role: .user, content: "TEXT:\nexample in"),
            .init(role: .assistant, content: "Example out."),
            .init(role: .user, content: "TEXT:\nEarlier two."),
            .init(role: .assistant, content: "Earlier two."),
            .init(role: .user, content: "TEXT:\nthe text to fix"),
        ])
    }

    @Test func withoutExamplesOrContextOnlyTheTextIsSent() {
        let request = Prompt.request(
            for: "hello",
            context: [],
            contextLimit: 3,
            template: PromptTemplate(system: "Fix the TEXT.", examples: [])
        )
        #expect(request.messages == [
            .init(role: .system, content: "Fix the TEXT."),
            .init(role: .user, content: "TEXT:\nhello"),
        ])
    }

    @Test func thinkingIsDisabled() {
        let request = Prompt.request(for: "hello", context: [], contextLimit: 3)
        #expect(request.templateContext["enable_thinking"] == false)
    }

    @Test func requestsUseTheStrictCleanupTemplateByDefault() {
        let request = Prompt.request(for: "hello", context: [], contextLimit: 3)
        #expect(request.messages == [
            .init(role: .system, content: Prompt.cleanup.system),
            .init(role: .user, content: "TEXT:\nhello"),
        ])
        #expect(Prompt.cleanup.system.contains("Do not add, remove, summarise or rephrase content."))
        #expect(Prompt.cleanup.system.contains("Output only the corrected text."))
    }

    @Test func tokenBudgetIsTwicePerWordPlusAllowance() {
        #expect(Prompt.maxTokens(for: "one two three") == 2 * 3 + 16)
        #expect(Prompt.request(for: "a b c d e", context: [], contextLimit: 0).maxTokens == 26)
    }

    @Test func placeholdersGetExtraTokenBudget() {
        #expect(Prompt.maxTokens(for: "send ⟦S1⟧ and ⟦S2⟧") == 2 * 4 + 2 * 6 + 16)
    }
}
