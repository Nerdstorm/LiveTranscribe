import Capture
@testable import Dictation
import Foundation
import os
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

/// Capture whose reader outlives it: its stream fails only when the test calls ``end()``, even
/// after the recorder has closed it and opened another capture. Cancelling the reader does not
/// end it sooner, the way a reader still busy with a last buffer finishes late.
actor LingeringAudioSource: AudioSource {
    private var ending: CheckedContinuation<Void, Never>?
    private var ended = false

    func start() -> AsyncThrowingStream<[Float], Error> {
        AsyncThrowingStream(unfolding: { [self] in
            await self.waitForEnd()
            throw CaptureFailed()
        })
    }

    func stop() {}

    func end() {
        ended = true
        ending?.resume()
        ending = nil
    }

    private func waitForEnd() async {
        guard !ended else { return }
        await withCheckedContinuation { ending = $0 }
    }
}

@Suite("DictationRecorder")
struct DictationRecorderTests {
    private let source = ScriptedAudioSource()

    private func recorder(preRollMs: Int = 10, maxDurationSeconds: Int = 60) -> DictationRecorder {
        let source = self.source
        return DictationRecorder(
            makeSource: { _ in source },
            configuration: .init(preRollMs: preRollMs, maxDurationSeconds: maxDurationSeconds)
        )
    }

    /// Lets the recorder's pump deliver what was pushed.
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))
    }

    /// The recorder's first event, or `nil` when none arrives within a second. Reading stops the
    /// event stream, so call it once per recorder.
    private func firstEvent(of recorder: DictationRecorder) async -> DictationRecorder.Event? {
        await withTaskGroup(of: DictationRecorder.Event?.self) { group in
            group.addTask {
                for await event in recorder.events { return event }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(1))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
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

    @Test func aCaptureFailureDuringARecordingIsReportedAtOnce() async throws {
        let recorder = recorder()
        try await recorder.start()
        await source.push([0.1])
        await settle()
        #expect(await !recorder.hasLostCapture)

        await source.fail(CaptureFailed())
        #expect(await firstEvent(of: recorder) == .captureEnded)
        #expect(await recorder.hasLostCapture)
        #expect(await recorder.stop().failure == "microphone unplugged")
        #expect(await !recorder.hasLostCapture, "it concerned the recording that stopped")
    }

    @Test func captureEndingByItselfDuringARecordingIsAFailureToo() async throws {
        let recorder = recorder()
        try await recorder.start()
        await source.push([0.1])
        await settle()
        // The stream finishes without an error, and not because the recorder closed it.
        await source.stop()

        #expect(await firstEvent(of: recorder) == .captureEnded)
        let recording = await recorder.stop()
        #expect(recording.samples == [0.1])
        #expect(recording.failure != nil)
    }

    @Test func aCaptureFailureWhileKeptReadyIsNotAboutARecording() async throws {
        let recorder = recorder()
        try await recorder.setKeepReady(true)
        await source.fail(CaptureFailed())
        await settle()
        #expect(await !recorder.hasLostCapture)

        try await recorder.start()
        #expect(await source.starts == 2, "the recording opens capture again")
        await source.push([0.2])
        await settle()
        let recording = await recorder.stop()
        #expect(recording.samples == [0.2])
        #expect(recording.failure == nil)
    }

    @Test func aReaderThatOutlivesItsCaptureDoesNotEndTheNextRecording() async throws {
        let first = LingeringAudioSource()
        let next = source
        let opened = OSAllocatedUnfairLock(initialState: 0)
        let recorder = DictationRecorder(
            makeSource: { _ -> any AudioSource in
                opened.withLock { count in
                    count += 1
                    return count == 1 ? first : next
                }
            },
            configuration: .init(preRollMs: 10, maxDurationSeconds: 60)
        )
        try await recorder.start()
        await settle()  // its reader is now waiting for audio
        _ = await recorder.stop()
        try await recorder.start()

        // The first capture's reader fails only now, while the next recording runs.
        await first.end()
        await settle()
        #expect(await !recorder.hasLostCapture)
        await next.push([0.2])
        await settle()
        let recording = await recorder.stop()
        #expect(recording.samples == [0.2])
        #expect(recording.failure == nil)
        #expect(await next.stops == 1, "the next capture is still the recorder's to close")
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

    // MARK: - Microphone choice

    /// A recorder that notes which microphone each capture was made for.
    private func recorder(choosing deviceUID: String?, opened: OSAllocatedUnfairLock<[String?]>) -> DictationRecorder {
        let source = self.source
        return DictationRecorder(
            makeSource: { uid in
                opened.withLock { $0.append(uid) }
                return source
            },
            configuration: .init(preRollMs: 10, maxDurationSeconds: 60, inputDeviceUID: deviceUID)
        )
    }

    @Test func aNewChoiceReopensTheMicrophoneKeptReady() async throws {
        let opened = OSAllocatedUnfairLock<[String?]>(initialState: [])
        let recorder = recorder(choosing: nil, opened: opened)
        try await recorder.setKeepReady(true)
        await recorder.update(.init(preRollMs: 10, maxDurationSeconds: 60, inputDeviceUID: "usb-mic"))
        #expect(opened.withLock { $0 } == [nil, "usb-mic"])
        #expect(await source.stops == 1, "the old capture is closed first")
        #expect(await source.isOpen, "and the new one is kept ready")

        await recorder.update(.init(preRollMs: 20, maxDurationSeconds: 60, inputDeviceUID: "usb-mic"))
        #expect(opened.withLock { $0 }.count == 2, "other settings leave capture open")
    }

    @Test func aChoiceMadeWhileRecordingAppliesAfterTheRecording() async throws {
        let opened = OSAllocatedUnfairLock<[String?]>(initialState: [])
        let recorder = recorder(choosing: "built-in", opened: opened)
        try await recorder.setKeepReady(true)
        try await recorder.start()
        await recorder.update(.init(preRollMs: 10, maxDurationSeconds: 60, inputDeviceUID: "usb-mic"))
        await source.push([0.1])
        await settle()
        #expect(opened.withLock { $0 } == ["built-in"], "a recording is never interrupted")

        let recording = await recorder.stop()
        #expect(recording.samples == [0.1])
        #expect(opened.withLock { $0 } == ["built-in", "usb-mic"])
        #expect(await source.isOpen)
    }

    @Test func withoutKeepReadyTheNextRecordingUsesTheNewChoice() async throws {
        let opened = OSAllocatedUnfairLock<[String?]>(initialState: [])
        let recorder = recorder(choosing: "built-in", opened: opened)
        await recorder.update(.init(preRollMs: 10, maxDurationSeconds: 60, inputDeviceUID: "usb-mic"))
        #expect(opened.withLock { $0 }.isEmpty, "nothing opens while not kept ready")
        try await recorder.start()
        _ = await recorder.stop()
        #expect(opened.withLock { $0 } == ["usb-mic"])
    }

    @Test func levelIsTheBuffersRMS() {
        #expect(DictationRecorder.rms([]) == 0)
        #expect(abs(DictationRecorder.rms([0.5, -0.5]) - 0.5) < 1e-6)
        #expect(DictationRecorder.rms([4, 4]) == 1)
    }
}
