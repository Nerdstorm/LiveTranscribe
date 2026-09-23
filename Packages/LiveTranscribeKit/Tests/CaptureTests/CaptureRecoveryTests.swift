@testable import Capture
import Foundation
import Testing

private let builtIn = TestDevices.builtIn
private let headset = TestDevices.headset
private let teams = TestDevices.teams

/// ``CaptureSessionSource`` recovering from failures, and ending cleanly: when it restarts, when it
/// gives up and with which error, and that stopping or dropping the stream releases everything.
@Suite("CaptureSessionSource recovery and lifecycle")
struct CaptureRecoveryTests {
    private let opener = FakeCaptureSessionOpener()
    private let notices = NoticeRecorder()

    private func makeSource(
        selected: String?,
        catalog: FakeInputDeviceCatalog,
        maxAttempts: Int,
        maxRestartsPerMinute: Int
    ) -> CaptureSessionSource {
        makeFakeSource(
            selected: selected,
            catalog: catalog,
            opener: opener,
            notices: notices,
            maxAttempts: maxAttempts,
            maxRestartsPerMinute: maxRestartsPerMinute,
            rateWindow: .seconds(60)
        )
    }

    @Test func aRuntimeErrorReopensTheSameMicrophoneQuietly() async throws {
        let catalog = FakeInputDeviceCatalog(connected: [builtIn], systemDefault: builtIn)
        let source = makeSource(selected: nil, catalog: catalog, maxAttempts: 1, maxRestartsPerMinute: 5)
        var audio = try await source.start().makeAsyncIterator()
        #expect(try await audio.next() == [0])

        opener.interrupt(0, with: .runtimeError("device reconfigured"))
        #expect(try await audio.next() == [1], "the stream carries on after the restart")
        #expect(opener.openedDeviceIDs == [builtIn.id, builtIn.id])
        #expect(opener.isStopped(0) == true)
        #expect(await source.activeDevice == builtIn)
        #expect(notices.all.isEmpty, "nothing changed that the user needs to know about")
        await source.stop()
    }

    @Test func recoveryEndsTheStreamWhenNoMicrophoneRemains() async throws {
        let catalog = FakeInputDeviceCatalog(connected: [builtIn], systemDefault: builtIn)
        let source = makeSource(selected: nil, catalog: catalog, maxAttempts: 2, maxRestartsPerMinute: 5)
        var audio = try await source.start().makeAsyncIterator()
        #expect(try await audio.next() == [0])

        catalog.update(connected: [], systemDefault: nil)
        opener.interrupt(0, with: .deviceDisconnected)
        #expect(await failure(of: &audio) as? CaptureError == .noInputDevice)
        try await waitUntil { catalog.endedObservations == 1 }
        #expect(catalog.endedObservations == 1, "device changes are no longer observed")
        #expect(await source.activeDevice == nil)
    }

    @Test func aChosenMicrophoneLostWithOnlyVirtualDevicesLeftEndsClearly() async throws {
        let catalog = FakeInputDeviceCatalog(connected: [headset, teams], systemDefault: headset)
        let source = makeSource(selected: headset.id, catalog: catalog, maxAttempts: 2, maxRestartsPerMinute: 5)
        var audio = try await source.start().makeAsyncIterator()
        #expect(try await audio.next() == [0])

        catalog.update(connected: [teams], systemDefault: teams)
        opener.interrupt(0, with: .deviceDisconnected)
        #expect(await failure(of: &audio) as? CaptureError == .inputDeviceUnavailable)
        #expect(opener.openedDeviceIDs == [headset.id], "the virtual device is never opened in its place")
        #expect(notices.all.isEmpty)
    }

    @Test func recoveryGivesUpAfterItsAttempts() async throws {
        let catalog = FakeInputDeviceCatalog(connected: [builtIn], systemDefault: builtIn)
        let source = makeSource(selected: nil, catalog: catalog, maxAttempts: 2, maxRestartsPerMinute: 5)
        var audio = try await source.start().makeAsyncIterator()
        #expect(try await audio.next() == [0])
        opener.failOpens(of: builtIn.id, times: 2)

        opener.interrupt(0, with: .runtimeError("busy"))
        #expect(await failure(of: &audio) as? CaptureError == .restartFailed(attempts: 2))
        #expect(opener.openedDeviceIDs == [builtIn.id])
    }

    @Test func tooManyRecoveriesInAMinuteStopCapture() async throws {
        let catalog = FakeInputDeviceCatalog(connected: [builtIn], systemDefault: builtIn)
        let source = makeSource(selected: nil, catalog: catalog, maxAttempts: 1, maxRestartsPerMinute: 1)
        var audio = try await source.start().makeAsyncIterator()
        #expect(try await audio.next() == [0])

        opener.interrupt(0, with: .runtimeError("first"))
        #expect(try await audio.next() == [1], "the first recovery is allowed")
        opener.interrupt(1, with: .runtimeError("second"))
        #expect(await failure(of: &audio) as? CaptureError == .tooManyRestarts(restarts: 1))
        #expect(opener.isStopped(1) == true)
        try await waitUntil { catalog.endedObservations == 1 }
        #expect(catalog.endedObservations == 1)
    }

    @Test func stopEndsTheStreamAndReleasesEverything() async throws {
        let catalog = FakeInputDeviceCatalog(connected: [builtIn], systemDefault: builtIn)
        let source = makeSource(selected: nil, catalog: catalog, maxAttempts: 1, maxRestartsPerMinute: 5)
        var audio = try await source.start().makeAsyncIterator()
        await source.stop()
        #expect(try await audio.next() == [0], "audio already delivered is kept")
        #expect(try await audio.next() == nil)
        #expect(opener.isStopped(0) == true)
        try await waitUntil { catalog.endedObservations == 1 }
        #expect(catalog.endedObservations == 1)
    }

    @Test func droppingTheStreamStopsCapture() async throws {
        let catalog = FakeInputDeviceCatalog(connected: [builtIn], systemDefault: builtIn)
        let source = makeSource(selected: nil, catalog: catalog, maxAttempts: 1, maxRestartsPerMinute: 5)
        _ = try await source.start()

        try await waitUntil { opener.isStopped(0) == true && catalog.endedObservations == 1 }
        #expect(opener.isStopped(0) == true, "a consumer that went away releases the microphone")
        #expect(catalog.endedObservations == 1)
        #expect(await source.activeDevice == nil)
    }

    @Test func startingTwiceIsRefused() async throws {
        let catalog = FakeInputDeviceCatalog(connected: [builtIn], systemDefault: builtIn)
        let source = makeSource(selected: nil, catalog: catalog, maxAttempts: 1, maxRestartsPerMinute: 5)
        let stream = try await source.start()
        await #expect(throws: CaptureError.alreadyRunning) {
            _ = try await source.start()
        }
        #expect(opener.openedDeviceIDs == [builtIn.id])
        withExtendedLifetime(stream) {}
        await source.stop()
    }

    @Test func aStoppedSourceStartsAgain() async throws {
        let catalog = FakeInputDeviceCatalog(connected: [builtIn], systemDefault: builtIn)
        let source = makeSource(selected: nil, catalog: catalog, maxAttempts: 1, maxRestartsPerMinute: 5)
        let first = try await source.start()
        await source.stop()
        var audio = try await source.start().makeAsyncIterator()
        #expect(try await audio.next() == [1])
        #expect(await source.activeDevice == builtIn)
        withExtendedLifetime(first) {}
        await source.stop()
    }
}
