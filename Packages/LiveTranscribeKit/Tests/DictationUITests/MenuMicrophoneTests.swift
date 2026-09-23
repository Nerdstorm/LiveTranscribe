import Capture
@testable import DictationUI
import Testing

@Suite("Microphone menu")
struct MenuMicrophoneTests {
    private let builtIn = AudioInputDevice(id: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone")
    private let usb = AudioInputDevice(id: "AppleUSBAudioEngine:Rode:1", name: "Rode NT-USB")
    private let loopback = AudioInputDevice(id: "ZoomAudioDevice", name: "ZoomAudioDevice", isVirtual: true)

    private func menu(selected: String? = nil, showOther: Bool = false, defaultName: String? = "MacBook Pro Microphone") -> MicrophoneMenu {
        MicrophoneMenu(
            devices: [builtIn, loopback, usb],
            selectedUID: selected,
            systemDefaultName: defaultName,
            showOtherDevices: showOther
        )
    }

    @Test func systemDefaultComesFirstAndNamesTheDefaultInput() {
        #expect(menu().systemDefault.title == "System Default (MacBook Pro Microphone)")
        #expect(menu(defaultName: nil).systemDefault.title == "System Default")
        #expect(menu().allItems.first?.uid == nil)
    }

    @Test func followingTheDefaultChecksOnlySystemDefault() {
        let items = menu(showOther: true).allItems
        #expect(items.filter(\.isSelected).map(\.uid) == [nil])
    }

    @Test func physicalMicrophonesAreListedInOrderAndVirtualOnesAreHidden() {
        let hidden = menu()
        #expect(hidden.devices.map(\.title) == ["MacBook Pro Microphone", "Rode NT-USB"])
        #expect(hidden.otherDevices.isEmpty)
    }

    @Test func showOtherDevicesListsVirtualOnesAfterThePhysicalOnes() {
        let shown = menu(showOther: true)
        #expect(shown.devices.map(\.uid) == [builtIn.id, usb.id])
        #expect(shown.otherDevices.map(\.uid) == [loopback.id])
        #expect(shown.allItems.map(\.uid) == [nil, builtIn.id, usb.id, loopback.id])
    }

    @Test func aChosenVirtualDeviceStaysListedAndChecked() {
        let chosen = menu(selected: loopback.id, showOther: false)
        #expect(chosen.otherDevices.map(\.uid) == [loopback.id])
        #expect(chosen.otherDevices.first?.isSelected == true)
        #expect(!chosen.systemDefault.isSelected)
    }

    @Test func aChosenMicrophoneThatIsMissingIsListedAsDisconnected() {
        let missing = menu(selected: "Shokz-OpenComm2")
        let last = missing.devices.last
        #expect(last?.title == "Shokz-OpenComm2 (disconnected)")
        #expect(last?.isSelected == true)
        #expect(last?.isDisconnected == true)
        #expect(missing.allItems.filter(\.isSelected).count == 1)
    }

    @Test func aConnectedChoiceIsCheckedWhereItIs() {
        let chosen = menu(selected: usb.id)
        #expect(chosen.devices.map(\.isSelected) == [false, true])
        #expect(chosen.devices.allSatisfy { !$0.isDisconnected })
    }

    @Test func longUIDsAreShortenedInTheMiddle() {
        let uid = "AppleUSBAudioEngine:Vendor:Product:0123456789ABCDEF0123456789:1,2"
        let short = MicrophoneMenu.shortenedUID(uid)
        #expect(short.count == 39)
        #expect(short.hasPrefix("AppleUSBAudioEngine"))
        #expect(short.hasSuffix(":1,2"))
        #expect(short.contains("…"))
        #expect(MicrophoneMenu.shortenedUID("BuiltIn") == "BuiltIn")
    }

    @Test func noDevicesLeavesOnlySystemDefault() {
        let empty = MicrophoneMenu(devices: [], selectedUID: nil, systemDefaultName: nil, showOtherDevices: true)
        #expect(empty.allItems.map(\.title) == ["System Default"])
    }
}
