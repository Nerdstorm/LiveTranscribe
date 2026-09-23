@testable import Capture
import Foundation
import os
import Testing

/// Devices shared by the policy and capture tests. `connected` lists keep this order.
enum TestDevices {
    static let builtIn = AudioInputDevice(id: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone")
    static let usb = AudioInputDevice(id: "AppleUSBAudioEngine:Yeti", name: "Yeti")
    static let headset = AudioInputDevice(id: "00-11-22-33-44-55:input", name: "OpenComm2")
    static let teams = AudioInputDevice(id: "MSTeamsAudioDevice", name: "Microsoft Teams Audio", isVirtual: true)
    static let aggregate = AudioInputDevice(id: "AggregateDevice-1", name: "Aggregate Device", isVirtual: true)
}

/// Input hardware in memory. `update` changes it and signals every observer, as a device
/// connecting or the default changing would.
final class FakeInputDeviceCatalog: InputDeviceCatalog {
    private struct State: Sendable {
        var snapshot: InputDeviceSnapshot
        var snapshotReads = 0
        var observers: [AsyncStream<Void>.Continuation] = []
        var endedObservations = 0
    }

    private let state: OSAllocatedUnfairLock<State>

    init(connected: [AudioInputDevice], systemDefault: AudioInputDevice?) {
        state = OSAllocatedUnfairLock(initialState: State(
            snapshot: InputDeviceSnapshot(connected: connected, systemDefault: systemDefault)
        ))
    }

    func snapshot() -> InputDeviceSnapshot {
        state.withLock { state in
            state.snapshotReads += 1
            return state.snapshot
        }
    }

    func changes() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        continuation.onTermination = { [state] _ in state.withLock { $0.endedObservations += 1 } }
        state.withLock { $0.observers.append(continuation) }
        return stream
    }

    func update(connected: [AudioInputDevice], systemDefault: AudioInputDevice?) {
        let observers = state.withLock { state in
            state.snapshot = InputDeviceSnapshot(connected: connected, systemDefault: systemDefault)
            return state.observers
        }
        for observer in observers {
            observer.yield()
        }
    }

    /// How often the hardware was read: a completed device review reads it once.
    var snapshotReads: Int { state.withLock { $0.snapshotReads } }
    var endedObservations: Int { state.withLock { $0.endedObservations } }
}

/// Capture sessions in memory. Each successful open yields one chunk, `[Float(index)]`, so
/// tests can see the stream is still delivering after a switch.
final class FakeCaptureSessionOpener: CaptureSessionOpening {
    private struct Session: Sendable {
        let deviceID: String
        let onInterruption: @Sendable (CaptureInterruption) -> Void
        var isStopped = false
    }

    private struct State: Sendable {
        var sessions: [Session] = []
        var failuresRemaining: [String: Int] = [:]
        var duringNextOpen: (@Sendable () -> Void)?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func open(
        _ device: AudioInputDevice,
        yieldingTo continuation: AsyncThrowingStream<[Float], Error>.Continuation,
        onInterruption: @escaping @Sendable (CaptureInterruption) -> Void
    ) throws -> any RunningCapture {
        let during = state.withLock { state in
            defer { state.duringNextOpen = nil }
            return state.duringNextOpen
        }
        during?()
        let index: Int? = state.withLock { state in
            if let remaining = state.failuresRemaining[device.id], remaining > 0 {
                state.failuresRemaining[device.id] = remaining - 1
                return nil
            }
            state.sessions.append(Session(deviceID: device.id, onInterruption: onInterruption))
            return state.sessions.count - 1
        }
        guard let index else { throw CaptureError.startFailed("fake open failure") }
        continuation.yield([Float(index)])
        return FakeRunningCapture(index: index, opener: self)
    }

    /// Runs `action` inside the next open, as the hardware changing while a device opens would.
    func duringNextOpen(_ action: @escaping @Sendable () -> Void) {
        state.withLock { $0.duringNextOpen = action }
    }

    /// The next `times` opens of this device throw.
    func failOpens(of deviceID: String, times: Int) {
        state.withLock { $0.failuresRemaining[deviceID] = times }
    }

    /// Reports a failure from session `index`, as AVFoundation would from any thread.
    func interrupt(_ index: Int, with interruption: CaptureInterruption) {
        let callback = state.withLock { $0.sessions.indices.contains(index) ? $0.sessions[index].onInterruption : nil }
        guard let callback else {
            Issue.record("No session \(index) to interrupt")
            return
        }
        callback(interruption)
    }

    var openedDeviceIDs: [String] { state.withLock { $0.sessions.map(\.deviceID) } }

    /// Whether session `index` was stopped, or `nil` if it was never opened.
    func isStopped(_ index: Int) -> Bool? {
        state.withLock { $0.sessions.indices.contains(index) ? $0.sessions[index].isStopped : nil }
    }

    fileprivate func markStopped(_ index: Int) {
        state.withLock { $0.sessions[index].isStopped = true }
    }
}

private final class FakeRunningCapture: RunningCapture {
    private let index: Int
    private let opener: FakeCaptureSessionOpener

    init(index: Int, opener: FakeCaptureSessionOpener) {
        self.index = index
        self.opener = opener
    }

    func stop() {
        opener.markStopped(index)
    }
}

/// Collects the notices a capture source reports.
final class NoticeRecorder: Sendable {
    private let notices = OSAllocatedUnfairLock<[CaptureNotice]>(initialState: [])

    var all: [CaptureNotice] { notices.withLock { $0 } }

    var callback: @Sendable (CaptureNotice) -> Void {
        { [notices] notice in notices.withLock { $0.append(notice) } }
    }
}

/// Polls until `condition` holds, for up to about five seconds. Callers `#expect` the outcome
/// afterwards, so a timeout fails with the actual values.
func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<1_000 where !condition() {
        try await Task.sleep(for: .milliseconds(5))
    }
}

/// A source over fake hardware that acts on device changes and retries at once (no delays).
/// Tests keep the returned stream alive until they stop the source: releasing it cancels
/// capture, as it would for a consumer that went away.
func makeFakeSource(
    selected: String?,
    catalog: FakeInputDeviceCatalog,
    opener: FakeCaptureSessionOpener,
    notices: NoticeRecorder,
    maxAttempts: Int,
    maxRestartsPerMinute: Int,
    rateWindow: Duration
) -> CaptureSessionSource {
    CaptureSessionSource(
        restartPolicy: CaptureRestartPolicy(maxAttempts: maxAttempts, delaySeconds: 0, maxRestartsPerMinute: maxRestartsPerMinute),
        inputDeviceUID: selected,
        onNotice: notices.callback,
        catalog: catalog,
        opener: opener,
        rateWindow: rateWindow
    )
}

/// Reads the stream to its end and returns the error it ended with, or `nil` if it finished.
func failure(of audio: inout AsyncThrowingStream<[Float], Error>.AsyncIterator) async -> (any Error)? {
    do {
        while try await audio.next() != nil {}
        return nil
    } catch {
        return error
    }
}
