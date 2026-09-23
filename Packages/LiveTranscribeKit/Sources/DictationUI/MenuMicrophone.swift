import Capture

/// The items of the menu's *Microphone* submenu, in order.
///
/// Pure, so the listing rules are unit-tested:
/// - *System Default* comes first, naming the current default input.
/// - Physical microphones follow. Virtual and aggregate devices (a meeting app's loopback, a
///   routing tool) are listed after them only when *Show Other Devices* is on, because they
///   usually carry other apps' audio or silence (docs/dictation.md, decision M1).
/// - The chosen microphone is always listed, even when it is virtual and the others are hidden,
///   or when it is disconnected, so the checkmark is never lost.
///
/// Nothing here selects a device: only the user's click does.
struct MicrophoneMenu: Equatable, Sendable {
    /// One selectable microphone.
    struct Item: Identifiable, Equatable, Sendable {
        /// The device UID, or `nil` for *System Default*.
        let uid: String?
        let title: String
        let isSelected: Bool
        /// The chosen microphone is not connected; capture uses the system default meanwhile.
        let isDisconnected: Bool

        var id: String { uid ?? "" }
    }

    /// Longest device UID shown for a disconnected microphone. UIDs of USB and Bluetooth devices
    /// can be long strings of hex, and a menu is as wide as its widest item.
    private static let uidLimit = 40

    let systemDefault: Item
    /// Physical microphones, then a disconnected chosen one.
    let devices: [Item]
    /// Virtual and aggregate devices, when shown.
    let otherDevices: [Item]

    /// - Parameters:
    ///   - devices: the connected input devices, virtual ones included and flagged.
    ///   - selectedUID: the chosen microphone's UID; `nil` follows the system default.
    ///   - systemDefaultName: the current default input's name, if there is one.
    ///   - showOtherDevices: the *Show Other Devices* setting.
    init(devices: [AudioInputDevice], selectedUID: String?, systemDefaultName: String?, showOtherDevices: Bool) {
        systemDefault = Item(
            uid: nil,
            title: systemDefaultName.map { "System Default (\($0))" } ?? "System Default",
            isSelected: selectedUID == nil,
            isDisconnected: false
        )
        func item(_ device: AudioInputDevice) -> Item {
            Item(uid: device.id, title: device.name, isSelected: device.id == selectedUID, isDisconnected: false)
        }
        var physical = devices.filter { !$0.isVirtual }.map(item)
        otherDevices = devices
            .filter { $0.isVirtual && (showOtherDevices || $0.id == selectedUID) }
            .map(item)
        if let selectedUID, !devices.contains(where: { $0.id == selectedUID }) {
            physical.append(Item(
                uid: selectedUID,
                title: "\(Self.shortenedUID(selectedUID)) (disconnected)",
                isSelected: true,
                isDisconnected: true
            ))
        }
        self.devices = physical
    }

    /// Every item in menu order.
    var allItems: [Item] { [systemDefault] + devices + otherDevices }

    /// Keeps the start and end of a long UID, where the vendor and the serial usually are.
    static func shortenedUID(_ uid: String) -> String {
        guard uid.count > uidLimit else { return uid }
        let half = (uidLimit - 1) / 2
        return "\(uid.prefix(half))…\(uid.suffix(half))"
    }
}
