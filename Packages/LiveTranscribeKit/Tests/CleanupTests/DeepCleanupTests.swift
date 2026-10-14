@testable import Cleanup
import Foundation
import Shared
import Testing

@Suite("CleanupExecutor: Deep")
struct DeepCleanupTests {
    private static let kirk = "I tried to speak with Kirk, but he didn't. I don't think he actually check whether the release is tomorrow. No, sorry, the after tomorrow."
    private static let repaired = "I tried to speak with Kirk, but he didn't. I don't think he actually checked whether the release is the day after tomorrow."

    /// A deadline no test meets by chance on a busy machine, except those that pass their own.
    private func executor(_ deep: DeepCleanup, timeout: Double = 30) -> CleanupExecutor {
        CleanupExecutor(contextLimit: 3, timeoutSeconds: timeout, prompts: PromptBuilder(adapted: true), deep: deep)
    }

    private static func deep(
        passes: DeepCleanup.Passes = .one,
        adapter: CleanupRequest.Adapter = .off,
        thinking: Bool = false,
        fallsBackToStandard: Bool = false,
        minimumTimeoutSeconds: Double = 0
    ) -> DeepCleanup {
        DeepCleanup(
            passes: passes, adapter: adapter, thinking: thinking, thinkingTokens: 64,
            fallsBackToStandard: fallsBackToStandard, minimumTimeoutSeconds: minimumTimeoutSeconds
        )
    }

    private func segment(_ text: String) -> Segment {
        Segment(id: UUID(), sessionID: UUID(), startMs: 0, endMs: 1_000, rawText: text)
    }

    @Test func onePassSendsDeepsPromptAndAcceptsTheRepair() async {
        let requests = Requests()
        let cleaned = await executor(Self.deep()).run(segment(Self.kirk), context: [], options: CleanupOptions(level: .deep)) { request in
            await requests.record(request)
            return Self.repaired
        }
        #expect(!cleaned.fellBack)
        #expect(cleaned.cleanedText == Self.repaired)
        let sent = await requests.all
        #expect(sent.count == 1)
        #expect(sent.first?.messages.first?.content == PromptBuilder(adapted: true).template(for: CleanupOptions(level: .deep)).system)
        #expect(sent.first?.adapter == .off)
        #expect(sent.first?.thinks == false)
    }

    @Test(arguments: CleanupRequest.Adapter.allCases)
    func deepRunsWithTheAdapterItSays(_ adapter: CleanupRequest.Adapter) async {
        let requests = Requests()
        _ = await executor(Self.deep(adapter: adapter)).run(segment(Self.kirk), context: [], options: CleanupOptions(level: .deep)) { request in
            await requests.record(request)
            return Self.repaired
        }
        #expect(await requests.all.map(\.adapter) == [adapter])
    }

    @Test func theShippedDeepRunsWithDeepsAdapterAndNoThinking() {
        #expect(DeepCleanup.shipped.adapter == .deep)
        #expect(DeepCleanup.shipped.passes == .one)
        #expect(!DeepCleanup.shipped.thinking)
        #expect(DeepCleanup.shipped.fallsBackToStandard)
    }

    /// With a correction cue, Standard's cleanup is its two passes: the correcting pass on what
    /// was said, then the rewording pass on what that resolved.
    @Test func aRejectedRepairGetsStandardsCleanup() async {
        let raw = "the lease ends in april no wait may"
        let resolved = "The lease ends in May."
        let requests = Requests()
        let cleaned = await executor(Self.deep(adapter: .deep, fallsBackToStandard: true)).run(
            segment(raw), context: [], options: CleanupOptions(level: .deep)
        ) { request in
            await requests.record(request)
            // Deep's answer keeps the month taken back; Standard's resolves it.
            return request.adapter == .deep ? "The lease ends in April." : resolved
        }
        #expect(!cleaned.fellBack, "Standard's cleanup is a success")
        #expect(cleaned.cleanedText == resolved)
        let sent = await requests.all
        #expect(sent.map(\.adapter) == [.deep, .medium, .medium])
        #expect(sent[1].messages.first?.content == Prompt.adapted.system, "the correcting pass gets the prompt its adapter was trained on")
        #expect(sent[1].messages.last?.content == "TEXT:\n\(raw)", "Standard cleans what was said, not Deep's answer")
        #expect(sent[2].messages.first?.content == PromptBuilder(adapted: true).template(for: CleanupOptions(level: .standard)).system)
        #expect(sent[2].messages.last?.content == "TEXT:\n\(resolved)", "then rewords what it resolved")
    }

    @Test func withoutACueStandardsCleanupIsOneRewordingPass() async {
        let raw = "i think the build is broken on main"
        let answer = "I think the build is broken on main."
        let requests = Requests()
        let cleaned = await executor(Self.deep(adapter: .deep, fallsBackToStandard: true)).run(
            segment(raw), context: [], options: CleanupOptions(level: .deep)
        ) { request in
            await requests.record(request)
            return request.adapter == .deep ? "Here is the text: \(answer)" : answer
        }
        #expect(!cleaned.fellBack)
        #expect(cleaned.cleanedText == answer)
        let sent = await requests.all
        #expect(sent.map(\.adapter) == [.deep, .medium])
        #expect(sent.last?.messages.first?.content == PromptBuilder(adapted: true).template(for: CleanupOptions(level: .standard)).system)
    }

    /// Standard may reword; Deep may not, so a reworded answer of Standard's is not shown at Deep.
    @Test func aRewordingOfStandardsMustPassDeepsCheckToo() async {
        let raw = "i think the build is broken on main"
        let reworded = "I believe the build is broken on main."
        let outputGuard = OutputGuard()
        #expect(outputGuard.review(raw: raw, outcome: .completed(reworded), options: CleanupOptions(level: .standard)) == .accepted(reworded))
        #expect(outputGuard.review(raw: raw, outcome: .completed(reworded), options: CleanupOptions(level: .deep)) == .rejected(.invalidRepair))
        let cleaned = await executor(Self.deep(adapter: .deep, fallsBackToStandard: true)).run(
            segment(raw), context: [], options: CleanupOptions(level: .deep)
        ) { request in
            request.adapter == .deep ? "Here is the text: I think the build on main is broken." : reworded
        }
        #expect(cleaned.fellBack)
        #expect(cleaned.cleanedText == raw)
    }

    @Test func whenStandardsCleanupIsRejectedTooWhatWasSaidIsShown() async {
        let raw = "the lease ends in april no wait may"
        let cleaned = await executor(Self.deep(fallsBackToStandard: true)).run(segment(raw), context: [], options: CleanupOptions(level: .deep)) { _ in
            "The lease ends in April."
        }
        #expect(cleaned.fellBack)
        #expect(cleaned.fallbackReason == "changed more than a repair may", "the reason is Deep's")
        #expect(cleaned.cleanedText == raw)
    }

    /// Standard's guard accepts a correction that takes back the name with the word it corrects;
    /// Deep's check doesn't, so Deep shows what was said, not Standard's answer.
    @Test func standardsCleanupMustPassDeepsCheckToo() async {
        let raw = "Kofi's brother, no wait, not brother, cousin, is hosting the barbecue."
        let standard = "Cousin is hosting the barbecue."
        let outputGuard = OutputGuard()
        #expect(outputGuard.review(raw: raw, outcome: .completed(standard), options: CleanupOptions(level: .standard, pass: .correcting)) == .accepted(standard))
        #expect(outputGuard.review(raw: raw, outcome: .completed(standard), options: CleanupOptions(level: .deep)) == .rejected(.invalidRepair))

        let requests = Requests()
        let cleaned = await executor(Self.deep(adapter: .deep, fallsBackToStandard: true)).run(
            segment(raw), context: [], options: CleanupOptions(level: .deep)
        ) { request in
            await requests.record(request)
            return request.adapter == .deep ? "Here is the text: Kofi's cousin is hosting the barbecue." : standard
        }
        #expect(await requests.all.map(\.adapter) == [.deep, .medium, .medium])
        #expect(cleaned.fellBack)
        #expect(cleaned.fallbackReason == "preamble in output (here is)", "the reason is Deep's, for its own answer")
        #expect(cleaned.cleanedText == raw)
    }

    @Test func noAnswerInTimeIsNotRetried() async {
        let requests = Requests()
        let cleaned = await executor(Self.deep(fallsBackToStandard: true, minimumTimeoutSeconds: 0.1), timeout: 0.1).run(
            segment(Self.kirk), context: [], options: CleanupOptions(level: .deep)
        ) { request in
            await requests.record(request)
            try await Task.sleep(for: .seconds(1))
            return Self.repaired
        }
        #expect(cleaned.fellBack)
        #expect(await requests.all.count == 1)
    }

    @Test func withoutTheFallbackARejectedRepairShowsWhatWasSaid() async {
        let requests = Requests()
        let cleaned = await executor(Self.deep()).run(segment("the lease ends in april no wait may"), context: [], options: CleanupOptions(level: .deep)) { request in
            await requests.record(request)
            return "The lease ends in April."
        }
        #expect(cleaned.fellBack)
        #expect(await requests.all.count == 1)
    }

    @Test func afterCorrectingResolvesFirstThenRepairs() async {
        let requests = Requests()
        let raw = "The meeting is on Tuesday. Sorry, Wednesday. We will review the the budget."
        let resolved = "The meeting is on Wednesday. We will review the budget."
        let cleaned = await executor(Self.deep(passes: .afterCorrecting)).run(segment(raw), context: [], options: CleanupOptions(level: .deep)) { request in
            await requests.record(request)
            return resolved
        }
        #expect(cleaned.cleanedText == resolved)
        let sent = await requests.all
        #expect(sent.count == 2)
        #expect(sent.map(\.adapter) == [.medium, .off], "the correcting pass runs with the adapter it was trained with")
        #expect(sent.first?.messages.first?.content == Prompt.adapted.system)
        #expect(sent.last?.messages.last?.content == "TEXT:\n\(resolved)", "Deep repairs what the correcting pass resolved")
    }

    @Test func afterCorrectingKeepsItsResultWhenTheRepairIsRejected() async {
        let raw = "The meeting is on Tuesday. Sorry, Wednesday."
        let resolved = "The meeting is on Wednesday."
        let calls = Requests()
        let cleaned = await executor(Self.deep(passes: .afterCorrecting)).run(segment(raw), context: [], options: CleanupOptions(level: .deep)) { request in
            await calls.record(request)
            return await calls.all.count == 1 ? resolved : "The meeting is on Wednesday, as agreed."
        }
        #expect(!cleaned.fellBack)
        #expect(cleaned.cleanedText == resolved)
    }

    @Test func afterCorrectingRunsOnePassWithoutACue() async {
        let requests = Requests()
        _ = await executor(Self.deep(passes: .afterCorrecting)).run(segment("she don't know"), context: [], options: CleanupOptions(level: .deep)) { request in
            await requests.record(request)
            return "She doesn't know."
        }
        #expect(await requests.all.count == 1)
    }

    @Test func thinkingIsSampledAndItsReasoningRemoved() async {
        let requests = Requests()
        let cleaned = await executor(Self.deep(thinking: true)).run(segment(Self.kirk), context: [], options: CleanupOptions(level: .deep)) { request in
            await requests.record(request)
            return "<think>\nThe speaker corrects tomorrow to the day after tomorrow.\n</think>\n\n\(Self.repaired)"
        }
        #expect(!cleaned.fellBack)
        #expect(cleaned.cleanedText == Self.repaired)
        let request = await requests.all.first
        #expect(request?.thinks == true)
        #expect(request?.templateContext["enable_thinking"] == true)
        #expect(request?.sampling.temperature == 0.6 && request?.sampling.topK == 20)
        #expect(request?.sampling.seed != nil)
        #expect(request.map { $0.maxTokens == Prompt.maxTokens(for: Self.kirk) + 64 } == true)
    }

    @Test func unfinishedThinkingFallsBack() async {
        let cleaned = await executor(Self.deep(thinking: true)).run(segment(Self.kirk), context: [], options: CleanupOptions(level: .deep)) { _ in
            "<think>\nThe speaker says tomorrow, then"
        }
        #expect(cleaned.fellBack)
        #expect(cleaned.fallbackReason == "ran out of tokens while thinking")
        #expect(cleaned.cleanedText == Self.kirk)
    }

    @Test func thinkingTagsWithoutThinkingAreRejected() async {
        let cleaned = await executor(Self.deep()).run(segment(Self.kirk), context: [], options: CleanupOptions(level: .deep)) { _ in
            "<think></think>\(Self.repaired)"
        }
        #expect(cleaned.fallbackReason == "thinking tags in output")
    }

    @Test func deepGetsItsLongerDeadline() async {
        let cleaned = await executor(Self.deep(minimumTimeoutSeconds: 0.5), timeout: 0.05).run(
            segment(Self.kirk), context: [], options: CleanupOptions(level: .deep)
        ) { _ in
            try await Task.sleep(for: .milliseconds(200))
            return Self.repaired
        }
        #expect(!cleaned.fellBack, "Deep waits for its own minimum, not the shorter Advanced timeout")
    }

    @Test func theSameTextIsSampledTheSameWay() {
        let first = Prompt.request(for: Self.kirk, context: [], contextLimit: 0, thinkingTokens: 32)
        let second = Prompt.request(for: Self.kirk, context: [], contextLimit: 0, thinkingTokens: 32)
        let other = Prompt.request(for: "Something else.", context: [], contextLimit: 0, thinkingTokens: 32)
        #expect(first.sampling == second.sampling)
        #expect(first.sampling.seed != other.sampling.seed)
    }
}

@Suite("ThinkingOutput")
struct ThinkingOutputTests {
    @Test func stripsTheReasoning() {
        #expect(ThinkingOutput("<think>\nhmm\n</think>\n\nThe answer.") == .answer("\n\nThe answer."))
        #expect(ThinkingOutput("The answer.") == .answer("The answer."))
        #expect(ThinkingOutput("<think>a</think>b</think>c") == .answer("c"), "the answer follows the last closing tag")
        #expect(ThinkingOutput("<think>\nstill going") == .unfinished)
    }
}

@Suite("PromptBuilder: Deep")
struct DeepPromptTests {
    @Test func deepHasItsOwnInstructionWithOrWithoutTheAdapter() {
        let deep = CleanupOptions(level: .deep)
        let adapted = PromptBuilder(adapted: true).template(for: deep).system
        #expect(adapted == PromptBuilder(adapted: false).template(for: deep).system)
        #expect(adapted != PromptBuilder(adapted: true).template(for: CleanupOptions(level: .standard)).system)
        #expect(adapted.contains("later sentence"))
        #expect(adapted.hasSuffix("Output only the corrected text."))
    }

    @Test func layoutDependsOnTheField() {
        let multiline = PromptBuilder(adapted: true).template(for: CleanupOptions(level: .deep, multiline: true)).system
        let oneLine = PromptBuilder(adapted: true).template(for: CleanupOptions(level: .deep)).system
        #expect(multiline.contains("email or letter"))
        #expect(!oneLine.contains("email or letter"))
        #expect(oneLine.contains("without line breaks"))
    }

    @Test func standardsPassesIgnoreTheField() {
        for pass in [CleanupPass.correcting, .rewording] {
            let builder = PromptBuilder(adapted: true)
            #expect(builder.template(for: CleanupOptions(level: .standard, pass: pass, multiline: true))
                == builder.template(for: CleanupOptions(level: .standard, pass: pass)))
        }
    }

    @Test func deepHasNoWorkedExamples() {
        #expect(PromptBuilder(adapted: true).template(for: CleanupOptions(level: .deep, multiline: true)).examples.isEmpty)
    }
}

private actor Requests {
    private(set) var all: [CleanupRequest] = []

    func record(_ request: CleanupRequest) {
        all.append(request)
    }
}
