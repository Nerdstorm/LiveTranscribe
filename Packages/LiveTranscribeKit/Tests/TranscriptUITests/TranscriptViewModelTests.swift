import Capture
import Foundation
import Session
import Shared
import Testing
@testable import TranscriptUI

/// A session that only records intents; tests drive the view model with `apply(_:)`.
private final class FakeSession: SessionControlling, @unchecked Sendable {
    // @unchecked: events is a let; the counters are only touched from the main actor in tests.
    let events: AsyncStream<SessionEvent>
    let input: AsyncStream<SessionEvent>.Continuation
    @MainActor var startCalls = 0
    @MainActor var stopCalls = 0

    init() {
        (events, input) = AsyncStream.makeStream(of: SessionEvent.self)
    }

    func prepare() async {}
    func cancelPreparation() async {}
    func start() async { await MainActor.run { startCalls += 1 } }
    func stop() async { await MainActor.run { stopCalls += 1 } }
    func retryCleanup() async {}
    func shutdown() async {}
}

/// Microphones in memory; `connect` and `disconnect` simulate a device appearing and going.
private final class FakeInputDevices: InputDeviceSelecting, @unchecked Sendable {
    // @unchecked: mutated only from the main actor in tests; the stream pair is immutable.
    var devices: [AudioInputDevice]
    var systemDefault: AudioInputDevice?
    var selected: String?
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init(devices: [AudioInputDevice], systemDefault: AudioInputDevice? = builtIn, selected: String? = nil) {
        self.devices = devices
        self.systemDefault = systemDefault
        self.selected = selected
        (stream, continuation) = AsyncStream.makeStream(of: Void.self)
    }

    func snapshot() -> InputDeviceSnapshot { InputDeviceSnapshot(connected: devices, systemDefault: systemDefault) }
    var selectedDeviceUID: String? { selected }
    func select(_ uid: String?) { selected = uid }
    func changes() -> AsyncStream<Void> { stream }

    func connect(_ device: AudioInputDevice) {
        devices.append(device)
        continuation.yield()
    }

    func disconnect(_ device: AudioInputDevice) {
        devices.removeAll { $0.id == device.id }
        continuation.yield()
    }
}

private let builtIn = AudioInputDevice(id: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone")
private let headset = AudioInputDevice(id: "00-11-22:input", name: "OpenComm2")
private let loopback = AudioInputDevice(id: "ZoomAudioDevice", name: "ZoomAudioDevice", isVirtual: true)

private func segment(_ id: UUID, _ text: String) -> Segment {
    Segment(id: id, sessionID: UUID(), startMs: 0, endMs: 1_000, rawText: text)
}

@MainActor
@Suite("TranscriptViewModel")
struct TranscriptViewModelTests {
    private let session = FakeSession()
    private var model: TranscriptViewModel { TranscriptViewModel(session: session, sessionsDirectory: nil) }

    @Test func phaseTransitionsFromIdleThroughLoadingToListeningAndError() {
        let model = self.model
        #expect(model.phase == .notLoaded)
        #expect(!model.canToggleListening)

        model.apply(.phase(.loading))
        model.apply(.modelProgress(ModelLoadProgress(modelID: "stt", stage: .downloading, fractionCompleted: 0.5)))
        #expect(model.modelProgress.count == 1)
        #expect(!model.canToggleListening)

        model.apply(.phase(.ready))
        #expect(model.canToggleListening)
        #expect(model.modelProgress.isEmpty)

        model.apply(.phase(.listening))
        #expect(model.isListening)
        #expect(model.canToggleListening)

        model.apply(.phase(.failed(.audioCaptureFailed(message: "device gone"))))
        #expect(!model.isListening)
        #expect(model.canToggleListening, "restarting capture is allowed after a device failure")

        model.apply(.phase(.failed(.modelLoadFailed(model: "stt", message: "offline"))))
        #expect(!model.canToggleListening)
    }

    @Test func progressUpdatesReplaceTheSameModel() {
        let model = self.model
        model.apply(.modelProgress(ModelLoadProgress(modelID: "a", stage: .downloading, fractionCompleted: 0.1)))
        model.apply(.modelProgress(ModelLoadProgress(modelID: "b", stage: .loading)))
        model.apply(.modelProgress(ModelLoadProgress(modelID: "a", stage: .ready, fractionCompleted: 1)))
        #expect(model.modelProgress.map(\.modelID) == ["a", "b"])
        #expect(model.modelProgress.first?.stage == .ready)
    }

    @Test func partialThenRawThenCleanedReplaceOneLine() {
        let model = self.model
        let id = UUID()
        model.apply(.cleanupAvailability(.available))
        model.apply(.sessionStarted(sessionID: UUID(), transcriptFile: nil))
        model.apply(.partial(segmentID: id, text: "i think"))
        #expect(model.lines == [TranscriptLine(id: id, text: "i think", rawText: nil, state: .partial)])

        model.apply(.partial(segmentID: id, text: "i think we should"))
        #expect(model.lines.first?.text == "i think we should")

        model.apply(.transcribed(segment(id, "i think we should go")))
        #expect(model.lines.first?.state == .raw(awaitingCleanup: true))

        let raw = segment(id, "i think we should go")
        model.apply(.cleaned(CleanedSegment(segment: raw, cleanedText: "I think we should go.", fellBack: false, fallbackReason: nil, latencyMs: 300)))
        #expect(model.lines.count == 1)
        #expect(model.lines.first?.text == "I think we should go.")
        #expect(model.lines.first?.state == .cleaned)
        #expect(model.lines.first?.rawText == "i think we should go")
    }

    @Test func lateOrDiscardedPartialsAreIgnored() {
        let model = self.model
        let id = UUID()
        model.apply(.transcribed(segment(id, "final text")))
        model.apply(.partial(segmentID: id, text: "stale partial"))
        #expect(model.lines.first?.text == "final text")

        let noise = UUID()
        model.apply(.partial(segmentID: noise, text: "hmm"))
        model.apply(.discarded(segmentID: noise))
        #expect(model.lines.map(\.id) == [id])
    }

    @Test func rawLinesAreFinalWhenCleanupIsNotRunning() {
        let model = self.model
        model.apply(.cleanupAvailability(.disabled))
        model.apply(.sessionStarted(sessionID: UUID(), transcriptFile: nil))
        model.apply(.transcribed(segment(UUID(), "raw only")))
        #expect(model.lines.first?.state == .raw(awaitingCleanup: false))
        #expect(model.lines.first?.isFinal == true)
    }

    @Test func fallbackIsShownWithItsReason() {
        let model = self.model
        let raw = segment(UUID(), "keep me")
        model.apply(.cleaned(.fallback(raw, reason: "timed out after 3.0s", latencyMs: 3_000)))
        #expect(model.lines.first?.state == .fellBack(reason: "timed out after 3.0s"))
        #expect(model.lines.first?.text == "keep me")
    }

    @Test func newSessionClearsTheTranscript() {
        let model = self.model
        model.apply(.transcribed(segment(UUID(), "old")))
        model.apply(.sessionStarted(sessionID: UUID(), transcriptFile: URL(fileURLWithPath: "/tmp/s.jsonl")))
        #expect(model.lines.isEmpty)
        #expect(model.transcriptFile?.lastPathComponent == "s.jsonl")
    }

    @Test func copyTextSkipsPartials() {
        let model = self.model
        model.apply(.transcribed(segment(UUID(), "First.")))
        model.apply(.transcribed(segment(UUID(), "Second.")))
        model.apply(.partial(segmentID: UUID(), text: "still talk"))
        #expect(model.transcriptText == "First.\nSecond.")
    }

    @Test func toggleStartsOrStopsDependingOnPhase() async throws {
        let model = self.model
        model.apply(.phase(.ready))
        model.toggleListening()
        try await waitUntil { session.startCalls == 1 }
        model.apply(.phase(.listening))
        model.toggleListening()
        try await waitUntil { session.stopCalls == 1 }
    }

    @Test func stopListeningStopsAListeningSessionAndNeverStartsOne() async throws {
        let model = self.model
        model.apply(.phase(.listening))
        model.stopListening()
        try await waitUntil { session.stopCalls == 1 }

        // Closing the window of a session that is not listening must not start one.
        for phase in [SessionPhase.ready, .loading, .stopping, .failed(.audioCaptureFailed(message: "x"))] {
            model.apply(.phase(phase))
            model.stopListening()
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(session.startCalls == 0)
        #expect(session.stopCalls == 1)
    }

    @Test func aStartUnderWayWhenAskedToStopIsStoppedOnceItListens() async throws {
        let model = self.model
        model.apply(.phase(.ready))
        model.toggleListening()
        try await waitUntil { session.startCalls == 1 }
        // The window closes while the microphone is still opening.
        model.stopListening()
        #expect(session.stopCalls == 0)
        model.apply(.phase(.listening))
        try await waitUntil { session.stopCalls == 1 }
    }

    @Test func aNewStartIsNotStoppedByAnEarlierStopRequest() async throws {
        let model = self.model
        model.apply(.phase(.ready))
        // Closed while nothing was starting, then started again from the window.
        model.stopListening()
        model.toggleListening()
        try await waitUntil { session.startCalls == 1 }
        model.apply(.phase(.listening))
        try await Task.sleep(for: .milliseconds(50))
        #expect(session.stopCalls == 0)
        #expect(model.isListening)
    }

    @Test func warningsCanBeDismissed() {
        let model = self.model
        model.apply(.warning("disk full"))
        #expect(model.warning == "disk full")
        model.dismissWarning()
        #expect(model.warning == nil)
    }

    // MARK: - Microphone selection

    @Test func attachLoadsDevicesAndTheSavedChoice() {
        let devices = FakeInputDevices(devices: [builtIn, headset], selected: headset.id)
        let model = TranscriptViewModel(session: session, sessionsDirectory: nil, inputSelection: devices)
        #expect(model.inputDevices.connected.isEmpty, "devices load on attach, not in init")
        model.attach()
        #expect(model.inputDevices == InputDeviceSnapshot(connected: [builtIn, headset], systemDefault: builtIn))
        #expect(model.selectedInputDeviceUID == headset.id)
        let list = model.microphoneList(showVirtualDevices: false)
        #expect(list.systemDefault.title == "System Default (MacBook Pro Microphone)")
        #expect(list.selectedRow.uid == headset.id)
        #expect(list.selectedRow.kind == .microphone)
    }

    @Test func thePickerListFollowsShowOtherDevices() {
        let devices = FakeInputDevices(devices: [builtIn, loopback])
        let model = TranscriptViewModel(session: session, sessionsDirectory: nil, inputSelection: devices)
        model.attach()
        #expect(model.microphoneList(showVirtualDevices: false).rows.map(\.uid) == [nil, builtIn.id])
        #expect(model.microphoneList(showVirtualDevices: true).rows.map(\.uid) == [nil, builtIn.id, loopback.id])
    }

    @Test func systemDefaultNamesThePhysicalMicrophoneWhenTheDefaultIsVirtual() {
        let devices = FakeInputDevices(devices: [builtIn, loopback], systemDefault: loopback)
        let model = TranscriptViewModel(session: session, sessionsDirectory: nil, inputSelection: devices)
        model.attach()
        #expect(model.microphoneList(showVirtualDevices: true).systemDefault.title == "System Default (MacBook Pro Microphone)")
    }

    @Test func selectingAMicrophonePersistsIt() {
        let devices = FakeInputDevices(devices: [builtIn, headset])
        let model = TranscriptViewModel(session: session, sessionsDirectory: nil, inputSelection: devices)
        model.attach()
        model.apply(.phase(.ready))
        model.selectInputDevice(builtIn.id)
        #expect(devices.selected == builtIn.id)
        #expect(model.selectedInputDeviceUID == builtIn.id)
        model.selectInputDevice(nil)
        #expect(devices.selected == nil, "nil returns to the system default")
    }

    @Test func microphoneIsLockedWhileListening() {
        let devices = FakeInputDevices(devices: [builtIn, headset], selected: builtIn.id)
        let model = TranscriptViewModel(session: session, sessionsDirectory: nil, inputSelection: devices)
        model.attach()
        model.apply(.phase(.listening))
        #expect(!model.canChangeInputDevice)
        model.selectInputDevice(headset.id)
        #expect(devices.selected == builtIn.id)
        model.apply(.phase(.failed(.audioCaptureFailed(message: "unstable"))))
        #expect(model.canChangeInputDevice, "a capture failure is fixed by picking another microphone")
    }

    @Test func disconnectedChoiceIsFlaggedUntilItReturns() async throws {
        let devices = FakeInputDevices(devices: [builtIn], selected: headset.id)
        let model = TranscriptViewModel(session: session, sessionsDirectory: nil, inputSelection: devices)
        model.attach()
        let missing = model.microphoneList(showVirtualDevices: false).selectedRow
        #expect(missing.kind == .disconnected)
        #expect(missing.title == "Disconnected microphone", "never seen, so only its UID is known")
        devices.connect(headset)
        try await waitUntil { model.inputDevices.connected.count == 2 }
        #expect(model.microphoneList(showVirtualDevices: false).selectedRow.kind == .microphone)
    }

    @Test func aChoiceThatDisconnectsKeepsItsName() async throws {
        let devices = FakeInputDevices(devices: [builtIn, headset], selected: headset.id)
        let model = TranscriptViewModel(session: session, sessionsDirectory: nil, inputSelection: devices)
        model.attach()
        devices.disconnect(headset)
        try await waitUntil { model.inputDevices.connected.count == 1 }
        let missing = model.microphoneList(showVirtualDevices: false).selectedRow
        #expect(missing.kind == .disconnected)
        #expect(missing.title == "OpenComm2 (disconnected)")
    }

    @Test func aVirtualChoiceThatDisconnectsStaysAmongTheOtherDevices() async throws {
        let devices = FakeInputDevices(devices: [builtIn, loopback], selected: loopback.id)
        let model = TranscriptViewModel(session: session, sessionsDirectory: nil, inputSelection: devices)
        model.attach()
        devices.disconnect(loopback)
        try await waitUntil { model.inputDevices.connected.count == 1 }
        let list = model.microphoneList(showVirtualDevices: false)
        #expect(list.otherDevices.map(\.uid) == [loopback.id])
        #expect(list.selectedRow.title == "ZoomAudioDevice (disconnected)")
    }

    @Test func withoutDeviceSelectionThePickerIsUnavailable() {
        let model = self.model
        #expect(!model.supportsInputSelection)
        #expect(!model.canChangeInputDevice)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(condition())
    }
}
