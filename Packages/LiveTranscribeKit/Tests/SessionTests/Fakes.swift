import Capture
import Cleanup
import Foundation
import Persistence
import Segmentation
@testable import Session
import Shared
import Transcription

struct FakeError: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

/// A microphone stand-in: the test pushes buffers, or scripts a failure.
actor FakeAudioSource: AudioSource {
    private var continuation: AsyncThrowingStream<[Float], Error>.Continuation?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start() -> AsyncThrowingStream<[Float], Error> {
        let (stream, continuation) = AsyncThrowingStream<[Float], Error>.makeStream()
        self.continuation = continuation
        startCount += 1
        return stream
    }

    func stop() {
        stopCount += 1
        continuation?.finish()
        continuation = nil
    }

    /// Pushes one utterance: the fake segmenter turns every buffer into one closed segment.
    func push(utterance index: Int) {
        continuation?.yield([Float](repeating: Float(index), count: 1_600))
    }

    func fail(_ error: Error) {
        continuation?.finish(throwing: error)
        continuation = nil
    }
}

/// Turns every buffer into one closed segment; `withPartial` also emits a partial for it first.
actor FakeSegmenter: SpeechSegmenter {
    var loadError: Error?
    var withPartial = false
    private var elapsedMs = 0

    func configure(loadError: Error? = nil, withPartial: Bool = false) {
        self.loadError = loadError
        self.withPartial = withPartial
    }

    func load(progress: @escaping ModelLoadProgressHandler) throws {
        if let loadError { throw loadError }
        progress(ModelLoadProgress(modelID: "fake-vad", stage: .ready, fractionCompleted: 1))
    }

    func reset() { elapsedMs = 0 }

    func process(_ samples: [Float]) -> [SegmentationEvent] {
        let id = UUID()
        let startMs = elapsedMs
        elapsedMs += AudioFormat.milliseconds(forSamples: samples.count)
        let audio = SpeechAudio(segmentID: id, startMs: startMs, endMs: elapsedMs, samples: samples, trailingSilenceMs: 600)
        var events: [SegmentationEvent] = [.speechStarted(segmentID: id, startMs: startMs)]
        if withPartial {
            // Partial audio is marked negative so the transcriber can tell it apart.
            events.append(.partial(SpeechAudio(segmentID: id, startMs: startMs, endMs: elapsedMs, samples: samples.map { -$0 - 1 }, trailingSilenceMs: 0)))
        }
        events.append(.closed(audio, reason: .silence))
        return events
    }

    func flush() -> [SegmentationEvent] { [] }
}

/// Transcribes utterance `n` as "utterance n"; partials (negative samples) are slow.
actor FakeTranscriber: Transcriber {
    var loadError: Error?
    var failingUtterances: Set<Int> = []
    var partialDelay: Duration = .zero
    private(set) var loadCount = 0

    func configure(loadError: Error? = nil, failingUtterances: Set<Int> = [], partialDelay: Duration = .zero) {
        self.loadError = loadError
        self.failingUtterances = failingUtterances
        self.partialDelay = partialDelay
    }

    func load(progress: @escaping ModelLoadProgressHandler) throws {
        loadCount += 1
        if let loadError { throw loadError }
    }

    func transcribe(_ samples: [Float], sampleRate: Int) async throws -> String {
        let marker = Int(samples.first ?? 0)
        if marker < 0 {
            try await Task.sleep(for: partialDelay)
            return "partial \(-marker - 1)"
        }
        if failingUtterances.contains(marker) { throw FakeError(message: "stt failed") }
        return "utterance \(marker)"
    }
}

/// Opens once; everything waiting on it resumes.
actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Whether anything is waiting for the gate to open.
    var hasWaiters: Bool { !waiters.isEmpty }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

/// Capitalises the first letter and adds a full stop, optionally after a gate or a delay,
/// or fails generation (through the real CleanupExecutor) to exercise the fallback path.
actor FakeCleaner: Cleaner {
    enum Behavior: Sendable {
        case correct
        case gated(Gate)
        case delayed(Duration)
        case failingGeneration
    }

    var behavior: Behavior = .correct
    var loadError: Error?
    private(set) var loadCount = 0
    private(set) var startedCount = 0
    private(set) var contexts: [[String]] = []

    func configure(behavior: Behavior = .correct, loadError: Error? = nil) {
        self.behavior = behavior
        self.loadError = loadError
    }

    func load(progress: @escaping ModelLoadProgressHandler) throws {
        loadCount += 1
        if let loadError { throw loadError }
    }

    func clean(_ segment: Segment, context: [String], options: CleanupOptions) async -> CleanedSegment {
        startedCount += 1
        contexts.append(context)
        switch behavior {
        case .correct: break
        case .gated(let gate): await gate.wait()
        case .delayed(let duration): try? await Task.sleep(for: duration)
        case .failingGeneration:
            return await CleanupExecutor(contextLimit: 3, timeoutSeconds: 1).run(segment, context: context, options: options) { _ in
                throw FakeError(message: "Metal device lost")
            }
        }
        let text = segment.rawText.prefix(1).uppercased() + segment.rawText.dropFirst() + "."
        return CleanedSegment(segment: segment, cleanedText: text, fellBack: false, fallbackReason: nil, latencyMs: 5)
    }
}

struct FakePermission: MicrophonePermissionProviding {
    let granted: Bool
    func status() -> MicrophonePermissionStatus { granted ? .granted : .denied }
    func request() async -> Bool { granted }
}

/// Records every coordinator event and lets tests wait for a condition.
actor EventRecorder {
    private(set) var events: [SessionEvent] = []

    init(_ stream: AsyncStream<SessionEvent>) {
        Task { await self.consume(stream) }
    }

    private func consume(_ stream: AsyncStream<SessionEvent>) async {
        for await event in stream {
            events.append(event)
        }
    }

    func waitUntil(
        timeout: Duration = .seconds(5),
        _ condition: @Sendable ([SessionEvent]) -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition(events) {
            guard ContinuousClock.now < deadline else {
                throw FakeError(message: "timed out waiting; events: \(events)")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

extension [SessionEvent] {
    var transcribed: [Segment] {
        compactMap { if case .transcribed(let segment) = $0 { segment } else { nil } }
    }

    var cleaned: [CleanedSegment] {
        compactMap { if case .cleaned(let cleaned) = $0 { cleaned } else { nil } }
    }

    var phases: [SessionPhase] {
        compactMap { if case .phase(let phase) = $0 { phase } else { nil } }
    }
}
