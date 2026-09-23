import Cleanup
import Foundation
import Shared
import Transcription

/// Returns a fixed transcript, or throws. ``hold()`` keeps a transcription waiting until
/// ``release()``, so a test can act while a dictation is processing.
actor FakeTranscriber: Transcriber {
    var transcript: String
    var error: Error?
    private(set) var calls = 0
    private var held = false
    private var heldCalls: [CheckedContinuation<Void, Never>] = []
    private var callWaiters: [CheckedContinuation<Void, Never>] = []

    init(transcript: String = "", error: Error? = nil) {
        self.transcript = transcript
        self.error = error
    }

    func set(transcript: String) { self.transcript = transcript }

    func load(progress: @escaping ModelLoadProgressHandler) async throws {}

    func transcribe(_ samples: [Float], sampleRate: Int) async throws -> String {
        calls += 1
        callWaiters.forEach { $0.resume() }
        callWaiters = []
        if held {
            await withCheckedContinuation { heldCalls.append($0) }
        }
        if let error { throw error }
        return transcript
    }

    func hold() { held = true }

    func release() {
        held = false
        heldCalls.forEach { $0.resume() }
        heldCalls = []
    }

    /// Returns once a transcription has started.
    func waitForCall() async {
        guard calls == 0 else { return }
        await withCheckedContinuation { callWaiters.append($0) }
    }
}

/// Runs the real ``CleanupExecutor`` (so filler removal and the output guard apply) with a
/// scripted model that answers from the text it was given.
actor ScriptedCleaner: Cleaner {
    private let reply: @Sendable (String) -> String
    private(set) var requests: [(text: String, options: CleanupOptions)] = []

    init(reply: @escaping @Sendable (String) -> String) {
        self.reply = reply
    }

    func load(progress: @escaping ModelLoadProgressHandler) async throws {}

    func clean(_ segment: Segment, context: [String], options: CleanupOptions) async -> CleanedSegment {
        let reply = self.reply
        let executor = CleanupExecutor(contextLimit: 0, timeoutSeconds: 1, prompts: PromptBuilder(adapted: true))
        return await executor.run(segment, context: context, options: options) { request in
            let text = request.messages.last?.content.replacingOccurrences(of: "TEXT:\n", with: "") ?? ""
            await self.record(text: text, options: options)
            return reply(text)
        }
    }

    private func record(text: String, options: CleanupOptions) {
        requests.append((text, options))
    }
}

struct FakeFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
