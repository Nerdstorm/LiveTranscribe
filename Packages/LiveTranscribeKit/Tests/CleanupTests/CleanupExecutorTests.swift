import Cleanup
import Foundation
import Shared
import Testing

@Suite("CleanupExecutor")
struct CleanupExecutorTests {
    private let segment = Segment(
        id: UUID(),
        sessionID: UUID(),
        startMs: 0,
        endMs: 1_500,
        rawText: "i think the build is broken on main"
    )

    private let medium = CleanupOptions(level: .medium)

    private func executor(timeout: Double = 1, adapted: Bool = false) -> CleanupExecutor {
        CleanupExecutor(contextLimit: 3, timeoutSeconds: timeout, prompts: PromptBuilder(adapted: adapted))
    }

    private func makeSegment(_ text: String) -> Segment {
        Segment(id: UUID(), sessionID: UUID(), startMs: 0, endMs: 1_000, rawText: text)
    }

    @Test func acceptedOutputReplacesRawText() async {
        let cleaned = await executor().run(segment, context: [], options: medium) { _ in "I think the build is broken on main." }
        #expect(!cleaned.fellBack)
        #expect(cleaned.cleanedText == "I think the build is broken on main.")
        #expect(cleaned.segment == segment)
    }

    @Test func generationErrorFallsBackToRaw() async {
        struct GPUFailure: LocalizedError { var errorDescription: String? { "GPU error" } }
        let cleaned = await executor().run(segment, context: [], options: medium) { _ in throw GPUFailure() }
        #expect(cleaned.fellBack)
        #expect(cleaned.cleanedText == segment.rawText)
        #expect(cleaned.fallbackReason == "generation failed: GPU error")
    }

    @Test func slowGenerationTimesOutAndFallsBack() async {
        let started = ContinuousClock.now
        let cleaned = await executor(timeout: 0.1).run(segment, context: [], options: medium) { _ in
            try await Task.sleep(for: .seconds(10))
            return "too late"
        }
        #expect(cleaned.fellBack)
        #expect(cleaned.fallbackReason == "timed out after 0.1s")
        #expect(started.duration(to: .now) < .seconds(2), "the generation is cancelled, not awaited")
    }

    @Test func guardRejectionFallsBack() async {
        let cleaned = await executor().run(segment, context: [], options: medium) { _ in "<think>hmm</think> I think the build is broken." }
        #expect(cleaned.fellBack)
        #expect(cleaned.fallbackReason == "thinking tags in output")
    }

    @Test func contextIsPassedThroughTheWindow() async {
        let captured = RequestRecorder()
        _ = await executor().run(segment, context: ["a.", "b.", "c.", "d."], options: medium) { request in
            await captured.record(request)
            return "I think the build is broken on main."
        }
        let request = await captured.last
        #expect(request?.messages.filter { $0.role == .assistant }.map(\.content) == ["b.", "c.", "d."])
        #expect(request?.messages.last == .init(role: .user, content: "TEXT:\n\(segment.rawText)"))
        #expect(request?.templateContext["enable_thinking"] == false)
    }

    @Test func emptyRawTextSkipsGeneration() async {
        let empty = Segment(id: UUID(), sessionID: UUID(), startMs: 0, endMs: 10, rawText: "  ")
        let cleaned = await executor().run(empty, context: [], options: CleanupOptions(level: .light)) { _ in
            Issue.record("generation should not run")
            return ""
        }
        #expect(!cleaned.fellBack)
        #expect(cleaned.cleanedText == "  ")
    }

    // MARK: - Levels

    @Test func levelNoneReturnsTheRawTextWithoutTheModel() async {
        let raw = makeSegment("um so the the build is broken")
        let cleaned = await executor().run(raw, context: [], options: CleanupOptions(level: .none)) { _ in
            Issue.record("generation should not run")
            return ""
        }
        #expect(cleaned == CleanedSegment(segment: raw, cleanedText: raw.rawText, fellBack: false, fallbackReason: nil, latencyMs: 0))
    }

    @Test func mediumRemovesFillersBeforeTheModelSeesTheText() async {
        let captured = RequestRecorder()
        let raw = makeSegment("so um the build is uh broken")
        let cleaned = await executor().run(raw, context: [], options: medium) { request in
            await captured.record(request)
            return "So the build is broken."
        }
        #expect(await captured.last?.messages.last == .init(role: .user, content: "TEXT:\nso the build is broken"))
        #expect(cleaned.cleanedText == "So the build is broken.")
        #expect(cleaned.segment == raw, "the record keeps what was actually said")
    }

    @Test func lightKeepsFillersForTheModel() async {
        let captured = RequestRecorder()
        let raw = makeSegment("so um the build is broken")
        _ = await executor().run(raw, context: [], options: CleanupOptions(level: .light)) { request in
            await captured.record(request)
            return "So, um, the build is broken."
        }
        #expect(await captured.last?.messages.last == .init(role: .user, content: "TEXT:\nso um the build is broken"))
    }

    @Test func aFallbackKeepsTheFillersRemoved() async {
        let raw = makeSegment("so um the build is uh broken")
        let cleaned = await executor().run(raw, context: [], options: medium) { _ in "Here is the text: So the build is broken." }
        #expect(cleaned.fellBack)
        #expect(cleaned.cleanedText == "so the build is broken")
    }

    @Test func onlyFillersLeavesNothingToClean() async {
        let cleaned = await executor().run(makeSegment("um uh"), context: [], options: medium) { _ in
            Issue.record("generation should not run")
            return ""
        }
        #expect(!cleaned.fellBack)
        #expect(cleaned.cleanedText.isEmpty)
    }

    @Test func optionsShapeThePrompt() async {
        let captured = RequestRecorder()
        let options = CleanupOptions(level: .high, vocabulary: ["Nerdstorm"], placeholders: ["⟦S1⟧"])
        let raw = makeSegment("email ⟦S1⟧ to the nerd storm team")
        let cleaned = await executor(adapted: true).run(raw, context: [], options: options) { request in
            await captured.record(request)
            return "Email ⟦S1⟧ to the Nerdstorm team."
        }
        let request = await captured.last
        #expect(request?.messages.first == .init(role: .system, content: PromptBuilder(adapted: true).template(for: options).system))
        #expect(cleaned.cleanedText == "Email ⟦S1⟧ to the Nerdstorm team.")
    }

    @Test func aDamagedPlaceholderFallsBackToTheTextWithPlaceholders() async {
        let options = CleanupOptions(level: .medium, placeholders: ["⟦S1⟧"])
        let raw = makeSegment("email ⟦S1⟧ to the team")
        let cleaned = await executor().run(raw, context: [], options: options) { _ in "Email S1 to the team." }
        #expect(cleaned.fellBack)
        #expect(cleaned.fallbackReason == "changed a snippet placeholder")
        #expect(cleaned.cleanedText == "email ⟦S1⟧ to the team")
    }
}

private actor RequestRecorder {
    private(set) var last: CleanupRequest?
    func record(_ request: CleanupRequest) { last = request }
}
