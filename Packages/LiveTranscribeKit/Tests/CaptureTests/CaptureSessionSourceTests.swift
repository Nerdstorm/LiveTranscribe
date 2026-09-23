@testable import Capture
import Foundation
import Testing

private let builtIn = TestDevices.builtIn
private let usb = TestDevices.usb
private let headset = TestDevices.headset
private let teams = TestDevices.teams

/// ``CaptureSessionSource`` with fake hardware and sessions: which device it opens, when it
/// switches, what it reports, and that the stream survives every switch. No microphone needed.
///
/// A device review runs as one job on the source's actor, so after waiting for its first visible
/// effect, tests await ``CaptureSessionSource/activeDevice`` before checking the rest.
@Suite("CaptureSessionSource device handling")
struct CaptureSessionSourceTests {
    private let opener = FakeCaptureSessionOpener()
    private let notices = NoticeRecorder()

    private func makeSource(
        selected: String?,
        catalog: FakeInputDeviceCatalog,
        maxAttempts: Int,
        maxRestartsPerMinute: Int,
        rateWindow: Duration = .seconds(60)
    ) -> CaptureSessionSource {
        makeFakeSource(
            selected: selected,
            catalog: catalog,
            opener: opener,
            notices: notices,
            maxAttempts: maxAttempts,
            maxRestartsPerMinute: maxRestartsPerMinute,
            rateWindow: rateWindow
        )
    }

    @Test func opensTheDefaultAndDeliversItsAudio() async throws {
        let catalog = FakeInputDeviceCatalog(connected: [builtIn, usb], systemDefault: usb)
        let source = makeSource(selected: nil, catalog: catalog, maxAttempts: 1, maxRestartsPerMinute: 5)
        var audio = try await source.start().makeAsyncIterator()
        #expect(try await audio.next() == [0])
        #expect(opener.openedDeviceIDs == [usb.id])
        #expect(await source.activeDevice == usb)
        #expect(notices.all.isEmpty)
        await source.stop()
        #expect(await source.activeDevice == nil)
    }

    @Test func aMissingChoiceFallsBackToTheDefaultAndSaysSo() async throws {
        let catalog = FakeInputDeviceCatalog(connected: [builtIn, usb], systemDefault: builtIn)
        let source = makeSource(selected: headset.id, catalog: catalog, maxAttempts: 1, maxRestartsPerMinute: 5)
        let stream = try await source.start()
        #expect(opener.openedDeviceIDs == [builtIn.id])
        #expect(notices.all == [.fellBackToDefault(missing: nil, using: builtIn.name)])
        withExtendedLifetime(stream) {}
        await source.stop()
    }

    @Test("Starting with nothing usable fails clearly and stops observing", arguments: [
        (nil, [AudioInputDevice](), CaptureError.noInputDevice),
        (headset.id, [], .noInputDevice),
        (headset.id, [teams], .inputDeviceUnavailable),
    ])
    func startingWithNothingUsableFails(selected: String?, connected: [AudioInputDevice], expected: CaptureError) async throws {
        let catalog = FakeInputDeviceCatalog(connected: connected, systemDefault: connected.first)
        let source = makeSource(selected: selected, catalog: catalog, maxAttempts: 1, maxRestartsPerMinute: 5)
        await #expect(throws: expected) {
            _ = try await source.start()
        }
        #expect(opener.openedDeviceIDs.isEmpty)
        try await waitUntil { catalog.endedObservations == 1 }
        #expect(catalog.endedObservations == 1, "a failed start does not leave the hardware observed")
        await source.stop()
    }

    @Test func followsANewDefaultWithoutEndingTheStream() async throws {
        let catalog = FakeInputDeviceCatalog(connected: [builtIn], systemDefault: builtIn)
        let source = makeSource(selected: nil, catalog: catalog, maxAttempts: 1, maxRestartsPerMinute: 5)
        var audio = try await source.start().makeAsyncIterator()
        #expect(try await audio.next() == [0])

        catalog.update(connected: [builtIn, usb], systemDefault: usb)
        try await waitUntil { opener.openedDeviceIDs.count == 2 }
        #expect(await source.activeDevice == usb)
        #expect(opener.openedDeviceIDs == [builtIn.id, usb.id])
        #expect(opener.isStopped(0) == true, "the old microphone is released")
        #expect(try await audio.next() == [1], "the same stream carries the new microphone's audio")
        #expect(notices.all == [.switchedDevice(name: usb.name)])
        await source.stop()
    }

    @Test func aDefaultChangeWhileTheFirstDeviceOpensIsNotMissed() async throws {
        let catalog = FakeInputDeviceCatalog(connected: [builtIn], systemDefault: builtIn)
        let source = makeSource(selected: nil, catalog: catalog, maxAttempts: 1, maxRestartsPerMinute: 5)
        opener.duringNextOpen { catalog.update(connected: [builtIn, usb], systemDefault: usb) }
        let stream = try await source.start()

        try await waitUntil { opener.openedDeviceIDs.count == 2 }
        #expect(await source.activeDevice == usb)
        #expect(opener.openedDeviceIDs == [builtIn.id, usb.id])
        #expect(notices.all == [.switchedDevice(name: usb.name)])
        withExtendedLifetime(stream) {}
        await source.stop()
    }

    @Test func aVirtualDefaultIsNotFollowed() async throws {
        let catalog = FakeInputDeviceCatalog(connected: [builtIn], systemDefault: builtIn)
        let source = makeSource(selected: nil, catalog: catalog, maxAttempts: 1, maxRestartsPerMinute: 5)
        let stream = try await source.start()

        catalog.update(connected: [builtIn, teams], systemDefault: teams)
        try await waitUntil { !notices.all.isEmpty }
        #expect(await source.activeDevice == builtIn)
        #expect(notices.all == [.keptDevice(current: builtIn.name, ignoredVirtual: teams.name)])
        #expect(opener.openedDeviceIDs == [builtIn.id])
        withExtendedLifetime(stream) {}
        await source.stop()
    }

    @Test func aChosenMicrophoneIgnoresDefaultChanges() async throws {
        let catalog = FakeInputDeviceCatalog(connected: [builtIn, headset], systemDefault: builtIn)
        let source = makeSource(selected: headset.id, catalog: catalog, maxAttempts: 1, maxRestartsPerMinute: 5)
        let stream = try await source.start()
        let readsAfterStart = catalog.snapshotReads

        catalog.update(connected: [builtIn, headset, usb], systemDefault: usb)
        try await waitUntil { catalog.snapshotReads > readsAfterStart }
        #expect(await source.activeDevice == headset)
        #expect(catalog.snapshotReads == readsAfterStart + 1, "the change was reviewed")
        #expect(opener.openedDeviceIDs == [headset.id])
        #expect(notices.all.isEmpty)
        withExtendedLifetime(stream) {}
        await source.stop()
    }

    @Test func aChosenMicrophoneThatDisconnectsFallsBackThenReturns() async throws {
        let catalog = FakeInputDeviceCatalog(connected: [builtIn, headset], systemDefault: builtIn)
        let source = makeSource(selected: headset.id, catalog: catalog, maxAttempts: 2, maxRestartsPerMinute: 5)
        var audio = try await source.start().makeAsyncIterator()
        #expect(try await audio.next() == [0])

        catalog.update(connected: [builtIn], systemDefault: builtIn)
        opener.interrupt(0, with: .deviceDisconnected)
        try await waitUntil { opener.openedDeviceIDs.count == 2 }
        #expect(await source.activeDevice == builtIn)
        #expect(opener.openedDeviceIDs == [headset.id, builtIn.id])
        #expect(notices.all == [.fellBackToDefault(missing: headset.name, using: builtIn.name)])
        #expect(try await audio.next() == [1], "falling back does not end the stream")

        catalog.update(connected: [builtIn, headset], systemDefault: builtIn)
        try await waitUntil { opener.openedDeviceIDs.count == 3 }
        #expect(await source.activeDevice == headset)
        #expect(opener.openedDeviceIDs == [headset.id, builtIn.id, headset.id])
        #expect(notices.all.last == .returnedToSelected(name: headset.name))
        #expect(try await audio.next() == [2])
        await source.stop()
    }

    @Test func followingTheDefaultRecoversOntoTheNewDefault() async throws {
        let catalog = FakeInputDeviceCatalog(connected: [builtIn, usb], systemDefault: usb)
        let source = makeSource(selected: nil, catalog: catalog, maxAttempts: 2, maxRestartsPerMinute: 5)
        let stream = try await source.start()

        catalog.update(connected: [builtIn], systemDefault: builtIn)
        opener.interrupt(0, with: .deviceDisconnected)
        try await waitUntil { opener.openedDeviceIDs.count == 2 }
        #expect(await source.activeDevice == builtIn)
        #expect(opener.openedDeviceIDs == [usb.id, builtIn.id])
        #expect(notices.all == [.switchedDevice(name: builtIn.name)])
        withExtendedLifetime(stream) {}
        await source.stop()
    }

    @Test func aFlappingDefaultIsRateLimited() async throws {
        let catalog = FakeInputDeviceCatalog(connected: [builtIn, usb], systemDefault: builtIn)
        let source = makeSource(selected: nil, catalog: catalog, maxAttempts: 1, maxRestartsPerMinute: 2)
        let stream = try await source.start()

        catalog.update(connected: [builtIn, usb], systemDefault: usb)
        try await waitUntil { opener.openedDeviceIDs.count == 2 }
        catalog.update(connected: [builtIn, usb], systemDefault: builtIn)
        try await waitUntil { opener.openedDeviceIDs.count == 3 }
        let readsBeforeThirdFlip = catalog.snapshotReads
        catalog.update(connected: [builtIn, usb], systemDefault: usb)
        try await waitUntil { catalog.snapshotReads > readsBeforeThirdFlip }

        #expect(await source.activeDevice == builtIn, "capture stays on the current microphone")
        #expect(opener.openedDeviceIDs == [builtIn.id, usb.id, builtIn.id], "the third switch in a minute is refused")
        #expect(opener.isStopped(2) == false)
        #expect(notices.all == [.switchedDevice(name: usb.name), .switchedDevice(name: builtIn.name)])
        withExtendedLifetime(stream) {}
        await source.stop()
    }

    @Test func aDefaultThatSettlesWhileSwitchesAreRefusedIsFollowedOnceAllowed() async throws {
        let catalog = FakeInputDeviceCatalog(connected: [builtIn, usb], systemDefault: builtIn)
        let source = makeSource(selected: nil, catalog: catalog, maxAttempts: 1, maxRestartsPerMinute: 2, rateWindow: .seconds(1))
        let stream = try await source.start()

        catalog.update(connected: [builtIn, usb], systemDefault: usb)
        try await waitUntil { opener.openedDeviceIDs.count == 2 }
        catalog.update(connected: [builtIn, usb], systemDefault: builtIn)
        try await waitUntil { opener.openedDeviceIDs.count == 3 }
        let readsBeforeThirdFlip = catalog.snapshotReads
        catalog.update(connected: [builtIn, usb], systemDefault: usb)
        try await waitUntil { catalog.snapshotReads > readsBeforeThirdFlip }
        #expect(await source.activeDevice == builtIn, "refused for now")

        // No further change arrives: the retry alone moves capture to where the default settled.
        try await waitUntil { opener.openedDeviceIDs.count == 4 }
        #expect(await source.activeDevice == usb)
        #expect(opener.openedDeviceIDs == [builtIn.id, usb.id, builtIn.id, usb.id])
        #expect(notices.all.last == .switchedDevice(name: usb.name))
        withExtendedLifetime(stream) {}
        await source.stop()
    }

    @Test func aFailedSwitchRecoversThroughTheRestartPath() async throws {
        let catalog = FakeInputDeviceCatalog(connected: [builtIn], systemDefault: builtIn)
        let source = makeSource(selected: nil, catalog: catalog, maxAttempts: 2, maxRestartsPerMinute: 5)
        let stream = try await source.start()
        opener.failOpens(of: usb.id, times: 1)

        catalog.update(connected: [builtIn, usb], systemDefault: usb)
        try await waitUntil { opener.openedDeviceIDs.count == 2 }
        #expect(await source.activeDevice == usb)
        #expect(opener.openedDeviceIDs == [builtIn.id, usb.id])
        #expect(notices.all == [.switchedDevice(name: usb.name)], "announced once, when it worked")
        withExtendedLifetime(stream) {}
        await source.stop()
    }

    @Test func aLateFailureFromAReplacedSessionIsIgnored() async throws {
        let catalog = FakeInputDeviceCatalog(connected: [builtIn], systemDefault: builtIn)
        let source = makeSource(selected: nil, catalog: catalog, maxAttempts: 1, maxRestartsPerMinute: 5)
        let stream = try await source.start()
        catalog.update(connected: [builtIn, usb], systemDefault: usb)
        try await waitUntil { opener.openedDeviceIDs.count == 2 }

        opener.interrupt(0, with: .runtimeError("late"))
        try await Task.sleep(for: .milliseconds(100))
        #expect(await source.activeDevice == usb)
        #expect(opener.openedDeviceIDs == [builtIn.id, usb.id], "no restart for a session already replaced")
        #expect(opener.isStopped(1) == false)
        withExtendedLifetime(stream) {}
        await source.stop()
    }
}
