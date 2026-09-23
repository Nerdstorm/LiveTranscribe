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

    private func executor(timeout: Double = 1) -> CleanupExecutor {
        CleanupExecutor(contextLimit: 3, timeoutSeconds: timeout)
    }

    @Test func acceptedOutputReplacesRawText() async {
        let cleaned = await executor().run(segment, context: []) { _ in "I think the build is broken on main." }
        #expect(!cleaned.fellBack)
        #expect(cleaned.cleanedText == "I think the build is broken on main.")
        #expect(cleaned.segment == segment)
    }

    @Test func generationErrorFallsBackToRaw() async {
        struct GPUFailure: LocalizedError { var errorDescription: String? { "GPU error" } }
        let cleaned = await executor().run(segment, context: []) { _ in throw GPUFailure() }
        #expect(cleaned.fellBack)
        #expect(cleaned.cleanedText == segment.rawText)
        #expect(cleaned.fallbackReason == "generation failed: GPU error")
    }

    @Test func slowGenerationTimesOutAndFallsBack() async {
        let started = ContinuousClock.now
        let cleaned = await executor(timeout: 0.1).run(segment, context: []) { _ in
            try await Task.sleep(for: .seconds(10))
            return "too late"
        }
        #expect(cleaned.fellBack)
        #expect(cleaned.fallbackReason == "timed out after 0.1s")
        #expect(started.duration(to: .now) < .seconds(2), "the generation is cancelled, not awaited")
    }

    @Test func guardRejectionFallsBack() async {
        let cleaned = await executor().run(segment, context: []) { _ in "<think>hmm</think> I think the build is broken." }
        #expect(cleaned.fellBack)
        #expect(cleaned.fallbackReason == "thinking tags in output")
    }

    @Test func contextIsPassedThroughTheWindow() async {
        let captured = RequestRecorder()
        _ = await executor().run(segment, context: ["a.", "b.", "c.", "d."]) { request in
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
        let cleaned = await executor().run(empty, context: []) { _ in
            Issue.record("generation should not run")
            return ""
        }
        #expect(!cleaned.fellBack)
        #expect(cleaned.cleanedText == "  ")
    }
}

private actor RequestRecorder {
    private(set) var last: CleanupRequest?
    func record(_ request: CleanupRequest) { last = request }
}
