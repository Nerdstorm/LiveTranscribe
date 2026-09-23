@testable import Capture
import Testing

private let builtIn = TestDevices.builtIn
private let usb = TestDevices.usb
private let headset = TestDevices.headset
private let teams = TestDevices.teams
private let aggregate = TestDevices.aggregate

/// Connected in name order, as the system catalog lists them: virtual ones between physical ones.
private let connected = [aggregate, builtIn, teams, usb]

private func list(
    _ devices: [AudioInputDevice] = connected,
    default systemDefault: AudioInputDevice? = builtIn,
    selected: String? = nil,
    showVirtual: Bool = false,
    lastSeen: AudioInputDevice? = nil
) -> MicrophonePickerList {
    MicrophonePickerList(
        snapshot: InputDeviceSnapshot(connected: devices, systemDefault: systemDefault),
        selectedUID: selected,
        showVirtualDevices: showVirtual,
        lastSeenChoice: lastSeen
    )
}

@Suite("Microphone picker list: rows")
struct MicrophonePickerListRowTests {
    @Test func systemDefaultComesFirstAndIsSelectedWhenNothingIsChosen() {
        let rows = list(showVirtual: true).rows
        #expect(rows.first?.uid == nil)
        #expect(rows.first?.kind == .systemDefault)
        #expect(rows.filter(\.isSelected).map(\.uid) == [nil])
    }

    @Test func virtualDevicesAreHiddenByDefault() {
        let hidden = list()
        #expect(hidden.microphones.map(\.uid) == [builtIn.id, usb.id], "physical ones, in catalog order")
        #expect(hidden.otherDevices.isEmpty)
        #expect(hidden.rows.allSatisfy { $0.kind != .otherDevice })
    }

    @Test func shownVirtualDevicesComeAfterThePhysicalOnes() {
        let shown = list(showVirtual: true)
        #expect(shown.microphones.map(\.uid) == [builtIn.id, usb.id])
        #expect(shown.otherDevices.map(\.uid) == [aggregate.id, teams.id])
        #expect(shown.otherDevices.allSatisfy { $0.kind == .otherDevice })
        #expect(shown.rows.map(\.uid) == [nil, builtIn.id, usb.id, aggregate.id, teams.id])
    }

    @Test func aChosenVirtualDeviceStaysListedAndSelectedWhenOthersAreHidden() {
        let chosen = list(selected: teams.id, showVirtual: false)
        #expect(chosen.otherDevices.map(\.uid) == [teams.id], "only the chosen one, not the aggregate")
        #expect(chosen.selectedRow.uid == teams.id)
        #expect(!chosen.systemDefault.isSelected)
    }

    @Test func hidingVirtualDevicesNeverChangesTheSelection() {
        for selected in [nil, builtIn.id, teams.id, "gone"] {
            #expect(
                list(selected: selected, showVirtual: true).selectedRow == list(selected: selected, showVirtual: false).selectedRow,
                "\(selected ?? "System Default")"
            )
        }
    }

    @Test func aConnectedChoiceIsSelectedWhereItIs() {
        let chosen = list(selected: usb.id)
        #expect(chosen.microphones.map(\.isSelected) == [false, true])
        #expect(chosen.rows.filter(\.isSelected).count == 1)
    }

    @Test("A virtual default is never selected for the user", arguments: [nil, builtIn.id])
    func aVirtualDefaultIsNeverSelected(selected: String?) {
        let rows = list(default: teams, selected: selected, showVirtual: true).rows
        #expect(rows.filter(\.isSelected).map(\.uid) == [selected])
    }

    @Test func noDevicesLeavesOnlySystemDefault() {
        let empty = list([], default: nil, showVirtual: true)
        #expect(empty.rows.map(\.title) == ["System Default"])
        #expect(empty.selectedRow == empty.systemDefault)
    }

    @Test func rowIDsAreUnique() {
        let rows = list(selected: "gone", showVirtual: true).rows
        #expect(Set(rows.map(\.id)).count == rows.count)
    }
}

@Suite("Microphone picker list: a disconnected choice")
struct MicrophonePickerListDisconnectedTests {
    @Test func isListedAfterTheMicrophonesAndSelected() {
        let missing = list(selected: headset.id)
        let last = missing.microphones.last
        #expect(last?.uid == headset.id)
        #expect(last?.kind == .disconnected)
        #expect(last?.isSelected == true)
        #expect(missing.selectedRow == last)
        #expect(missing.rows.filter(\.isSelected).count == 1)
    }

    @Test func isNamedWhenItWasSeenConnected() {
        #expect(list(selected: headset.id, lastSeen: headset).selectedRow.title == "OpenComm2 (disconnected)")
        #expect(list(selected: headset.id).selectedRow.title == "Disconnected microphone")
    }

    @Test func aLastSeenDeviceWithAnotherIDIsIgnored() {
        let other = AudioInputDevice(id: "other", name: "Other", isVirtual: true)
        let missing = list(selected: headset.id, lastSeen: other)
        #expect(missing.selectedRow.title == "Disconnected microphone")
        #expect(missing.microphones.last?.uid == headset.id)
    }

    @Test func aVirtualChoiceStaysAmongTheOtherDevices() {
        let loopback = AudioInputDevice(id: "LoopbackAudio", name: "Loopback Audio", isVirtual: true)
        let hidden = list(selected: loopback.id, showVirtual: false, lastSeen: loopback)
        #expect(hidden.microphones.map(\.uid) == [builtIn.id, usb.id])
        #expect(hidden.otherDevices.map(\.uid) == [loopback.id], "listed although other devices are hidden")
        #expect(hidden.selectedRow.title == "Loopback Audio (disconnected)")
        #expect(hidden.selectedRow.kind == .disconnected)
        let shown = list(selected: loopback.id, showVirtual: true, lastSeen: loopback)
        #expect(shown.otherDevices.map(\.uid) == [aggregate.id, teams.id, loopback.id], "last in its group")
    }

    @Test func aConnectedChoiceIgnoresTheLastSeenDevice() {
        let chosen = list(selected: usb.id, lastSeen: AudioInputDevice(id: usb.id, name: "Old name"))
        #expect(chosen.selectedRow.title == "Yeti")
        #expect(chosen.rows.allSatisfy { $0.kind != .disconnected })
    }
}

@Suite("Microphone picker list: System Default's label")
struct MicrophonePickerListSystemDefaultTests {
    @Test func namesAPhysicalDefault() {
        #expect(list(default: usb).systemDefault.title == "System Default (Yeti)")
    }

    @Test func namesThePhysicalMicrophoneCaptureUsesInsteadOfAVirtualDefault() {
        // Capture skips a virtual default for a physical microphone (decision M1).
        #expect(list(default: teams).systemDefault.title == "System Default (MacBook Pro Microphone)")
        #expect(list([teams, usb], default: teams).systemDefault.title == "System Default (Yeti)")
    }

    @Test func namesAVirtualDefaultOnlyWhenNoPhysicalMicrophoneIsConnected() {
        // Capture uses it at start then, so the label says so.
        #expect(list([aggregate, teams], default: teams).systemDefault.title == "System Default (Microsoft Teams Audio)")
    }

    @Test func namesTheMicrophoneUsedWhenThereIsNoDefault() {
        #expect(list(default: nil).systemDefault.title == "System Default (MacBook Pro Microphone)")
    }

    @Test func isPlainWhenNothingCanBeOpened() {
        #expect(list([], default: nil).systemDefault.title == "System Default")
        #expect(list([teams], default: nil).systemDefault.title == "System Default")
    }

    @Test("Names exactly the device capture opens for System Default", arguments: [
        InputDeviceSnapshot(connected: [builtIn, teams, usb], systemDefault: teams),
        InputDeviceSnapshot(connected: [aggregate, teams], systemDefault: aggregate),
        InputDeviceSnapshot(connected: [headset, usb], systemDefault: usb),
        InputDeviceSnapshot(connected: [teams, headset], systemDefault: nil),
    ])
    func agreesWithCapture(snapshot: InputDeviceSnapshot) throws {
        let opened = try InputDevicePolicy.deviceToOpen(selectedUID: nil, previous: nil, in: snapshot).device
        let title = MicrophonePickerList(snapshot: snapshot, selectedUID: nil, showVirtualDevices: false).systemDefault.title
        #expect(title == "System Default (\(opened.name))")
    }
}
