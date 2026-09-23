import Cleanup
import Foundation
import Shared
import Transcription

/// Returns a fixed transcript, or throws.
actor FakeTranscriber: Transcriber {
    var transcript: String
    var error: Error?
    private(set) var calls = 0

    init(transcript: String = "", error: Error? = nil) {
        self.transcript = transcript
        self.error = error
    }

    func set(transcript: String) { self.transcript = transcript }

    func load(progress: @escaping ModelLoadProgressHandler) async throws {}

    func transcribe(_ samples: [Float], sampleRate: Int) async throws -> String {
        calls += 1
        if let error { throw error }
        return transcript
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
