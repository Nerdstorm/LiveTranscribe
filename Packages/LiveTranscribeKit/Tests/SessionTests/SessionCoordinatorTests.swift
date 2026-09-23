import Foundation
import Persistence
@testable import Session
import Shared
import Testing

/// A coordinator wired to fakes, plus handles on each fake.
private struct Harness {
    let coordinator: SessionCoordinator
    let recorder: EventRecorder
    let source = FakeAudioSource()
    let segmenter = FakeSegmenter()
    let transcriber = FakeTranscriber()
    let cleaner = FakeCleaner()
    let sink = MemorySessionSink()

    init(settings: AppSettings = .defaults, micGranted: Bool = true) {
        let source = self.source
        let sink = self.sink
        coordinator = SessionCoordinator(
            settings: settings,
            dependencies: .init(
                makeAudioSource: { source },
                segmenter: segmenter,
                transcriber: transcriber,
                cleaner: cleaner,
                makeSink: { _ in sink },
                microphonePermission: FakePermission(granted: micGranted)
            )
        )
        recorder = EventRecorder(coordinator.events)
    }

    /// Loads models and starts listening.
    func startListening() async throws {
        await coordinator.prepare()
        await coordinator.start()
        try await recorder.waitUntil { $0.phases.last == .listening }
    }
}

@Suite("SessionCoordinator")
struct SessionCoordinatorTests {
    @Test func transcribesCleansAndSavesEachSegment() async throws {
        let h = Harness()
        try await h.startListening()
        for index in 1...3 { await h.source.push(utterance: index) }
        try await h.recorder.waitUntil { $0.cleaned.count == 3 }
        await h.coordinator.stop()

        let records = await h.sink.records
        #expect(records.map(\.rawText) == ["utterance 1", "utterance 2", "utterance 3"])
        #expect(records.map(\.cleanedText) == ["Utterance 1.", "Utterance 2.", "Utterance 3."])
        #expect(records.allSatisfy { !$0.fellBack && $0.latency.llmMs != nil && $0.latency.totalMs != nil })
        #expect(await h.sink.isClosed)
        #expect(await h.recorder.events.phases.last == .ready)
    }

    @Test func cleanerSeesPreviousCleanedSegmentsAsContext() async throws {
        var settings = AppSettings.defaults
        settings.contextSegments = 2
        let h = Harness(settings: settings)
        try await h.startListening()
        for index in 1...4 { await h.source.push(utterance: index) }
        try await h.recorder.waitUntil { $0.cleaned.count == 4 }
        await h.coordinator.stop()
        #expect(await h.cleaner.contexts == [[], ["Utterance 1."], ["Utterance 1.", "Utterance 2."], ["Utterance 2.", "Utterance 3."]])
    }

    @Test func deniedMicrophoneShowsRecoveryStateWithoutCapturing() async throws {
        let h = Harness(micGranted: false)
        await h.coordinator.prepare()
        await h.coordinator.start()
        try await h.recorder.waitUntil { $0.phases.last == .failed(.microphonePermissionDenied) }
        #expect(await h.source.startCount == 0)
    }

    @Test func cleanupDisabledNeverLoadsTheLLMAndSavesRawOnly() async throws {
        var settings = AppSettings.defaults
        settings.cleanupEnabled = false
        let h = Harness(settings: settings)
        try await h.startListening()
        await h.source.push(utterance: 1)
        try await h.recorder.waitUntil { $0.transcribed.count == 1 }
        await h.coordinator.stop()

        #expect(await h.cleaner.loadCount == 0)
        let records = await h.sink.records
        #expect(records.count == 1)
        #expect(records.first?.cleanedText == nil)
        #expect(records.first?.latency.llmMs == nil)
        let events = await h.recorder.events
        #expect(events.cleaned.isEmpty)
        #expect(events.contains(.cleanupAvailability(.disabled)))
    }

    @Test func overflowDropsTheOldestPendingJobButSavesItsRawText() async throws {
        var settings = AppSettings.defaults
        settings.cleanupQueueCapacity = 2
        let h = Harness(settings: settings)
        let gate = Gate()
        await h.cleaner.configure(behavior: .gated(gate))
        try await h.startListening()

        await h.source.push(utterance: 1)
        try await h.recorder.waitUntil { $0.transcribed.count == 1 }
        while await h.cleaner.startedCount < 1 { try await Task.sleep(for: .milliseconds(5)) }
        // Job 1 is in the cleaner; 2 and 3 fill the queue; 4 and 5 push out 2 and 3.
        for index in 2...5 { await h.source.push(utterance: index) }
        try await h.recorder.waitUntil { $0.transcribed.count == 5 && $0.cleaned.count == 2 }
        await gate.open()
        await h.coordinator.stop()

        let records = await h.sink.records
        #expect(records.count == 5)
        let dropped = records.filter { $0.fallbackReason == "cleanup queue full" }
        #expect(dropped.map(\.rawText) == ["utterance 2", "utterance 3"])
        #expect(dropped.allSatisfy { $0.fellBack && $0.cleanedText == $0.rawText })
        #expect(records.filter { !$0.fellBack }.map(\.rawText).sorted() == ["utterance 1", "utterance 4", "utterance 5"])
    }

    @Test func llmFailureFallsBackToRawText() async throws {
        let h = Harness()
        await h.cleaner.configure(behavior: .failingGeneration)
        try await h.startListening()
        await h.source.push(utterance: 1)
        try await h.recorder.waitUntil { $0.cleaned.count == 1 }
        await h.coordinator.stop()

        let cleaned = try #require(await h.recorder.events.cleaned.first)
        #expect(cleaned.fellBack)
        #expect(cleaned.cleanedText == "utterance 1")
        #expect(cleaned.fallbackReason == "generation failed: Metal device lost")
        #expect(await h.sink.records.first?.fellBack == true)
    }

    @Test func stopDrainsQueuedSegmentsAndFlushes() async throws {
        let h = Harness()
        await h.cleaner.configure(behavior: .delayed(.milliseconds(50)))
        try await h.startListening()
        for index in 1...3 { await h.source.push(utterance: index) }
        await h.coordinator.stop()

        // stop() returns only after everything queued was cleaned and saved.
        #expect(await h.sink.records.count == 3)
        #expect(await h.sink.isClosed)
        #expect(await h.source.stopCount >= 1)
        #expect(await h.recorder.events.cleaned.count == 3)
    }

    @Test func sttFailureSkipsTheSegmentAndKeepsGoing() async throws {
        let h = Harness()
        await h.transcriber.configure(failingUtterances: [2])
        try await h.startListening()
        for index in 1...3 { await h.source.push(utterance: index) }
        try await h.recorder.waitUntil { $0.cleaned.count == 2 }
        await h.coordinator.stop()

        #expect(await h.sink.records.map(\.rawText) == ["utterance 1", "utterance 3"])
        #expect(await h.recorder.events.contains { if case .discarded = $0 { true } else { false } })
    }

    @Test func sttLoadFailureNamesTheModel() async throws {
        let h = Harness()
        await h.transcriber.configure(loadError: FakeError(message: "offline"))
        await h.coordinator.prepare()
        let expected = SessionPhase.failed(.modelLoadFailed(model: AppSettings.defaults.sttModel, message: "offline"))
        try await h.recorder.waitUntil { $0.phases.last == expected }

        await h.coordinator.start()
        #expect(await h.source.startCount == 0, "cannot listen without STT")
    }

    @Test func llmLoadFailureRunsRawOnlyAndCanBeRetried() async throws {
        let h = Harness()
        await h.cleaner.configure(loadError: FakeError(message: "disk full"))
        await h.coordinator.prepare()
        try await h.recorder.waitUntil { $0.phases.last == .ready }
        #expect(await h.recorder.events.contains(.cleanupAvailability(.unavailable(model: AppSettings.defaults.llmModel, message: "disk full"))))

        await h.cleaner.configure(loadError: nil)
        await h.coordinator.retryCleanup()
        try await h.recorder.waitUntil { $0.last == .cleanupAvailability(.available) }
    }

    @Test func captureFailureEndsTheSessionAndFlushes() async throws {
        let h = Harness()
        try await h.startListening()
        await h.source.push(utterance: 1)
        try await h.recorder.waitUntil { $0.cleaned.count == 1 }
        await h.source.fail(FakeError(message: "device gone"))
        try await h.recorder.waitUntil { $0.phases.last == .failed(.audioCaptureFailed(message: "device gone")) }

        #expect(await h.sink.isClosed)
        #expect(await h.sink.records.count == 1)
        #expect(await h.source.stopCount >= 1, "the microphone is released")
    }

    @Test func partialsNeverArriveAfterTheFinalText() async throws {
        let h = Harness()
        await h.segmenter.configure(withPartial: true)
        await h.transcriber.configure(partialDelay: .milliseconds(100))
        try await h.startListening()
        await h.source.push(utterance: 1)
        try await h.recorder.waitUntil { $0.cleaned.count == 1 }
        try await Task.sleep(for: .milliseconds(200))
        await h.coordinator.stop()

        let events = await h.recorder.events
        let finalIndex = try #require(events.firstIndex { if case .transcribed = $0 { true } else { false } })
        let latePartial = events[finalIndex...].contains { if case .partial = $0 { true } else { false } }
        #expect(!latePartial)
    }
}
