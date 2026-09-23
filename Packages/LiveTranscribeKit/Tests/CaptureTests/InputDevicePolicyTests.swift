@testable import Capture
import Testing

private let builtIn = TestDevices.builtIn
private let usb = TestDevices.usb
private let headset = TestDevices.headset
private let teams = TestDevices.teams
private let aggregate = TestDevices.aggregate

private func snapshot(_ connected: [AudioInputDevice], default systemDefault: AudioInputDevice?) -> InputDeviceSnapshot {
    InputDeviceSnapshot(connected: connected, systemDefault: systemDefault)
}

private func open(
    selected: AudioInputDevice.ID?,
    previous: AudioInputDevice? = nil,
    _ snapshot: InputDeviceSnapshot
) throws(CaptureError) -> InputDeviceChoice {
    try InputDevicePolicy.deviceToOpen(selectedUID: selected, previous: previous, in: snapshot)
}

@Suite("InputDevicePolicy: a chosen microphone")
struct ChosenMicrophonePolicyTests {
    @Test("A connected choice is used, virtual or not", arguments: [builtIn, headset, teams])
    func connectedChoiceIsUsed(choice: AudioInputDevice) throws {
        let result = try open(selected: choice.id, snapshot([builtIn, headset, teams], default: usb))
        #expect(result == InputDeviceChoice(device: choice, notice: nil))
    }

    @Test func recoveringOnTheChoiceSaysNothing() throws {
        let result = try open(selected: headset.id, previous: headset, snapshot([builtIn, headset], default: builtIn))
        #expect(result == InputDeviceChoice(device: headset, notice: nil))
    }

    @Test func returningFromTheFallbackIsAnnounced() throws {
        let result = try open(selected: headset.id, previous: builtIn, snapshot([builtIn, headset], default: builtIn))
        #expect(result == InputDeviceChoice(device: headset, notice: .returnedToSelected(name: "OpenComm2")))
    }

    @Test func missingAtStartFallsBackToTheDefault() throws {
        let result = try open(selected: headset.id, snapshot([builtIn, usb], default: usb))
        #expect(result == InputDeviceChoice(device: usb, notice: .fellBackToDefault(missing: nil, using: "Yeti")))
    }

    @Test func disconnectingFallsBackToTheDefaultAndNamesTheLostDevice() throws {
        let result = try open(selected: headset.id, previous: headset, snapshot([builtIn, usb], default: usb))
        #expect(result == InputDeviceChoice(device: usb, notice: .fellBackToDefault(missing: "OpenComm2", using: "Yeti")))
    }

    @Test func aVirtualDefaultIsNotAFallback() throws {
        let result = try open(selected: headset.id, snapshot([builtIn, teams, usb], default: teams))
        #expect(result == InputDeviceChoice(device: builtIn, notice: .fellBackToDefault(missing: nil, using: "MacBook Pro Microphone")))
    }

    @Test func withAVirtualDefaultTheFallbackInUseIsKept() throws {
        let result = try open(selected: headset.id, previous: usb, snapshot([builtIn, teams, usb], default: teams))
        #expect(result == InputDeviceChoice(device: usb, notice: nil))
    }

    @Test func recoveringOnTheFallbackSaysNothing() throws {
        let result = try open(selected: headset.id, previous: builtIn, snapshot([builtIn, usb], default: builtIn))
        #expect(result == InputDeviceChoice(device: builtIn, notice: nil))
    }

    @Test func aFallbackThatDisconnectsIsReplacedWithASwitchNotice() throws {
        let result = try open(selected: headset.id, previous: usb, snapshot([builtIn], default: builtIn))
        #expect(result == InputDeviceChoice(device: builtIn, notice: .switchedDevice(name: "MacBook Pro Microphone")))
    }

    @Test func withoutADefaultTheFirstPhysicalMicrophoneIsUsed() throws {
        let result = try open(selected: headset.id, snapshot([teams, usb, builtIn], default: nil))
        #expect(result == InputDeviceChoice(device: usb, notice: .fellBackToDefault(missing: nil, using: "Yeti")))
    }

    @Test("Only virtual devices left: fails rather than falling back to one", arguments: [nil, headset])
    func onlyVirtualDevicesFail(previous: AudioInputDevice?) {
        #expect(throws: CaptureError.inputDeviceUnavailable) {
            try open(selected: headset.id, previous: previous, snapshot([teams, aggregate], default: teams))
        }
    }
}

@Suite("InputDevicePolicy: following the system default")
struct FollowingDefaultPolicyTests {
    @Test func aPhysicalDefaultIsUsedAtStart() throws {
        let result = try open(selected: nil, snapshot([builtIn, usb], default: usb))
        #expect(result == InputDeviceChoice(device: usb, notice: nil))
    }

    @Test func recoveringOntoANewDefaultIsAnnounced() throws {
        let result = try open(selected: nil, previous: headset, snapshot([builtIn, usb], default: builtIn))
        #expect(result == InputDeviceChoice(device: builtIn, notice: .switchedDevice(name: "MacBook Pro Microphone")))
    }

    @Test func recoveringOnTheSameDefaultSaysNothing() throws {
        let result = try open(selected: nil, previous: usb, snapshot([builtIn, usb], default: usb))
        #expect(result == InputDeviceChoice(device: usb, notice: nil))
    }

    @Test("A virtual default is skipped for a physical microphone", arguments: [teams, aggregate])
    func virtualDefaultIsSkipped(virtualDefault: AudioInputDevice) throws {
        let result = try open(selected: nil, snapshot([builtIn, virtualDefault], default: virtualDefault))
        #expect(result == InputDeviceChoice(
            device: builtIn,
            notice: .skippedVirtualDefault(virtual: virtualDefault.name, using: "MacBook Pro Microphone")
        ))
    }

    @Test func skippingAVirtualDefaultKeepsTheMicrophoneInUse() throws {
        let result = try open(selected: nil, previous: usb, snapshot([builtIn, teams, usb], default: teams))
        #expect(result == InputDeviceChoice(device: usb, notice: nil))
    }

    @Test func aVirtualDefaultIsUsedAtStartWhenNothingElseIsConnected() throws {
        let result = try open(selected: nil, snapshot([aggregate, teams], default: teams))
        #expect(result == InputDeviceChoice(device: teams, notice: nil))
    }

    @Test func aVirtualDefaultAlreadyInUseIsReopened() throws {
        let result = try open(selected: nil, previous: teams, snapshot([teams], default: teams))
        #expect(result == InputDeviceChoice(device: teams, notice: nil))
    }

    @Test func recoveringFromAVirtualDefaultOntoAPhysicalOneIsAnnounced() throws {
        let result = try open(selected: nil, previous: teams, snapshot([builtIn, teams], default: builtIn))
        #expect(result == InputDeviceChoice(device: builtIn, notice: .switchedDevice(name: "MacBook Pro Microphone")))
    }

    @Test func capturingNeverMovesToAVirtualDefaultMidSession() {
        #expect(throws: CaptureError.noInputDevice) {
            try open(selected: nil, previous: headset, snapshot([teams], default: teams))
        }
    }

    @Test func withoutADefaultTheFirstPhysicalMicrophoneIsUsed() throws {
        #expect(try open(selected: nil, snapshot([teams, usb], default: nil)) == InputDeviceChoice(device: usb, notice: nil))
        #expect(
            try open(selected: nil, previous: headset, snapshot([teams, usb], default: nil))
                == InputDeviceChoice(device: usb, notice: .switchedDevice(name: "Yeti"))
        )
    }

    @Test func aDefaultThatCannotBeOpenedYetIsIgnored() throws {
        let hardware = snapshot([builtIn], default: usb)
        #expect(hardware.systemDefault == nil, "a default that is not in the connected list is dropped")
        #expect(try open(selected: nil, hardware) == InputDeviceChoice(device: builtIn, notice: nil))
    }

    @Test("Nothing connected fails", arguments: [nil, headset.id])
    func nothingConnectedFails(selected: String?) {
        #expect(throws: CaptureError.noInputDevice) {
            try open(selected: selected, snapshot([], default: nil))
        }
    }
}

@Suite("InputDevicePolicy: changes while capturing")
struct DeviceChangePolicyTests {
    private func decide(
        selected: String?,
        current: AudioInputDevice,
        previousDefault: AudioInputDevice?,
        _ snapshot: InputDeviceSnapshot
    ) -> DeviceChangeDecision {
        InputDevicePolicy.decisionAfterChange(
            selectedUID: selected,
            current: current,
            previousDefaultUID: previousDefault?.id,
            in: snapshot
        )
    }

    @Test("A chosen microphone ignores default changes", arguments: [usb, teams])
    func chosenMicrophoneIgnoresDefaultChanges(newDefault: AudioInputDevice) {
        let decision = decide(selected: headset.id, current: headset, previousDefault: builtIn, snapshot([builtIn, headset, usb, teams], default: newDefault))
        #expect(decision == .keep(notice: nil))
    }

    @Test func theChosenMicrophoneIsReturnedToWhenItReconnects() {
        let decision = decide(selected: headset.id, current: builtIn, previousDefault: builtIn, snapshot([builtIn, headset], default: builtIn))
        #expect(decision == .switchTo(headset, notice: .returnedToSelected(name: "OpenComm2")))
    }

    @Test func onTheFallbackANewPhysicalDefaultIsFollowed() {
        let decision = decide(selected: headset.id, current: builtIn, previousDefault: builtIn, snapshot([builtIn, usb], default: usb))
        #expect(decision == .switchTo(usb, notice: .switchedDevice(name: "Yeti")))
    }

    @Test func onTheFallbackAVirtualDefaultIsNotFollowed() {
        let decision = decide(selected: headset.id, current: builtIn, previousDefault: builtIn, snapshot([builtIn, teams], default: teams))
        #expect(decision == .keep(notice: .keptDevice(current: "MacBook Pro Microphone", ignoredVirtual: "Microsoft Teams Audio")))
    }

    @Test func followingSwitchesToANewPhysicalDefault() {
        let decision = decide(selected: nil, current: builtIn, previousDefault: builtIn, snapshot([builtIn, usb], default: usb))
        #expect(decision == .switchTo(usb, notice: .switchedDevice(name: "Yeti")))
    }

    @Test func onAVirtualDefaultANewPhysicalDefaultIsFollowed() {
        // Started on the virtual default because nothing else was connected.
        let decision = decide(selected: nil, current: teams, previousDefault: teams, snapshot([teams, usb], default: usb))
        #expect(decision == .switchTo(usb, notice: .switchedDevice(name: "Yeti")))
    }

    @Test("Following keeps the device when the new default is virtual", arguments: [teams, aggregate])
    func followingKeepsTheDeviceForAVirtualDefault(virtualDefault: AudioInputDevice) {
        let decision = decide(selected: nil, current: builtIn, previousDefault: builtIn, snapshot([builtIn, virtualDefault], default: virtualDefault))
        #expect(decision == .keep(notice: .keptDevice(current: "MacBook Pro Microphone", ignoredVirtual: virtualDefault.name)))
    }

    @Test("An unchanged default is not acted on again", arguments: [teams, usb])
    func unchangedDefaultIsNotActedOnAgain(standingDefault: AudioInputDevice) {
        // Another device connected; the default is the one already decided about.
        let decision = decide(selected: nil, current: builtIn, previousDefault: standingDefault, snapshot([builtIn, standingDefault, headset], default: standingDefault))
        #expect(decision == .keep(notice: nil))
    }

    @Test func aDefaultReturningToTheCurrentDeviceSaysNothing() {
        let decision = decide(selected: nil, current: builtIn, previousDefault: teams, snapshot([builtIn, teams], default: builtIn))
        #expect(decision == .keep(notice: nil))
    }

    @Test func noDefaultKeepsTheDevice() {
        let decision = decide(selected: nil, current: builtIn, previousDefault: builtIn, snapshot([builtIn, usb], default: nil))
        #expect(decision == .keep(notice: nil))
    }

    @Test("A current device that has gone is left to disconnect recovery", arguments: [nil, headset.id])
    func goneDeviceIsLeftToRecovery(selected: String?) {
        let decision = decide(selected: selected, current: headset, previousDefault: headset, snapshot([builtIn], default: builtIn))
        #expect(decision == .keep(notice: nil))
    }

    @Test func aDefaultIsFollowedOnceItCanBeOpened() {
        // Core Audio reports the new default before AVFoundation lists it: nothing happens, and
        // the default is not recorded as seen, so the next change still switches.
        let early = snapshot([builtIn], default: usb)
        #expect(decide(selected: nil, current: builtIn, previousDefault: builtIn, early) == .keep(notice: nil))
        let listed = snapshot([builtIn, usb], default: usb)
        #expect(
            InputDevicePolicy.decisionAfterChange(selectedUID: nil, current: builtIn, previousDefaultUID: early.systemDefault?.id, in: listed)
                == .switchTo(usb, notice: .switchedDevice(name: "Yeti"))
        )
    }
}
