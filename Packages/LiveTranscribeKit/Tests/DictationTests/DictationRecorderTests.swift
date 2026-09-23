import Capture
@testable import Dictation
import Foundation
import Shared
import Testing

/// Audio pushed by the test; counts opens and closes.
actor ScriptedAudioSource: AudioSource {
    private var continuation: AsyncThrowingStream<[Float], Error>.Continuation?
    private(set) var starts = 0
    private(set) var stops = 0
    var startError: Error?

    func failNextStart(with error: Error) { startError = error }

    func start() throws -> AsyncThrowingStream<[Float], Error> {
        starts += 1
        if let startError {
            self.startError = nil
            throw startError
        }
        let (stream, continuation) = AsyncThrowingStream<[Float], Error>.makeStream()
        self.continuation = continuation
        return stream
    }

    func stop() {
        stops += 1
        continuation?.finish()
        continuation = nil
    }

    var isOpen: Bool { continuation != nil }

    func push(_ samples: [Float]) { continuation?.yield(samples) }

    func fail(_ error: Error) {
        continuation?.finish(throwing: error)
        continuation = nil
    }
}

struct CaptureFailed: LocalizedError {
    var errorDescription: String? { "microphone unplugged" }
}

@Suite("DictationRecorder")
struct DictationRecorderTests {
    private let source = ScriptedAudioSource()

    private func recorder(preRollMs: Int = 10, maxDurationSeconds: Int = 60) -> DictationRecorder {
        let source = self.source
        return DictationRecorder(
            makeSource: { source },
            configuration: .init(preRollMs: preRollMs, maxDurationSeconds: maxDurationSeconds)
        )
    }

    /// Lets the recorder's pump deliver what was pushed.
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))
    }

    @Test func capturesOnlyWhileRecordingAndClosesAfterwards() async throws {
        let recorder = recorder()
        try await recorder.start()
        #expect(await source.isOpen)
        await source.push([0.1, 0.2])
        await source.push([0.3])
        await settle()
        let recording = await recorder.stop()
        #expect(recording.samples == [0.1, 0.2, 0.3])
        #expect(!recording.truncated)
        #expect(recording.failure == nil)
        #expect(await source.stops == 1, "the microphone is released when not kept ready")
    }

    @Test func keptReadyStartsWithThePreRoll() async throws {
        let recorder = recorder(preRollMs: 1)  // 16 samples
        try await recorder.setKeepReady(true)
        await source.push([Float](repeating: 0.5, count: 40))
        await settle()
        try await recorder.start()
        await source.push([0.9])
        await settle()
        let recording = await recorder.stop()
        #expect(recording.samples == [Float](repeating: 0.5, count: 16) + [0.9])
        #expect(await source.stops == 0, "capture stays open while kept ready")
        #expect(await source.starts == 1)

        try await recorder.setKeepReady(false)
        #expect(await source.stops == 1)
    }

    @Test func aRecordingStopsGrowingAtTheLimit() async throws {
        let recorder = recorder(maxDurationSeconds: 1)
        try await recorder.start()
        await source.push([Float](repeating: 0.1, count: 10_000))
        await source.push([Float](repeating: 0.2, count: 10_000))
        await settle()
        let recording = await recorder.stop()
        #expect(recording.samples.count == AudioFormat.sampleRate)
        #expect(recording.truncated)
        #expect(recording.durationMs == 1_000)
    }

    @Test func aCaptureFailureKeepsWhatArrivedAndIsReported() async throws {
        let recorder = recorder()
        try await recorder.start()
        await source.push([0.1])
        await settle()
        await source.fail(CaptureFailed())
        await settle()
        let recording = await recorder.stop()
        #expect(recording.samples == [0.1])
        #expect(recording.failure == "microphone unplugged")

        try await recorder.start()
        #expect(await source.starts == 2, "the next recording opens capture again")
        _ = await recorder.stop()
    }

    @Test func aStartFailureThrowsAndLeavesNothingOpen() async throws {
        let recorder = recorder()
        await source.failNextStart(with: CaptureFailed())
        await #expect(throws: CaptureFailed.self) { try await recorder.start() }
        #expect(await recorder.stop().samples.isEmpty)
        #expect(await !source.isOpen)
    }

    @Test func cancelDiscardsAndReleasesTheMicrophone() async throws {
        let recorder = recorder()
        try await recorder.start()
        await source.push([0.1])
        await settle()
        await recorder.cancel()
        #expect(await source.stops == 1)
        #expect(await recorder.stop().samples.isEmpty)
    }

    @Test func levelIsTheBuffersRMS() {
        #expect(DictationRecorder.rms([]) == 0)
        #expect(abs(DictationRecorder.rms([0.5, -0.5]) - 0.5) < 1e-6)
        #expect(DictationRecorder.rms([4, 4]) == 1)
    }
}
