import Foundation

/// What a microphone picker lists, in order. The menu bar's *Microphone* submenu, Settings ›
/// General and the live transcript window all show this list, so they always agree.
///
/// Pure, so every rule is unit-tested (docs/dictation.md, decision M1):
/// - **System Default** comes first. It names the microphone capture would open for it at the
///   next start, as ``InputDevicePolicy`` picks it. That is macOS's default input, except when
///   the default is a virtual device and a physical microphone is connected: capture skips the
///   virtual default, so the label names the physical microphone used instead.
/// - **Microphones** (physical ones) follow in the catalog's order.
/// - **Other devices** (virtual and aggregate: a meeting app's loopback, a routing tool) come
///   last, and only when shown, because they usually carry other apps' audio or silence. A
///   chosen one is listed even when they are hidden, so hiding them never hides the selection.
/// - **A chosen microphone that is not connected** is listed last in its group, so the selection
///   is never blank: among the other devices if it was last seen as a virtual one, otherwise
///   after the microphones.
///
/// Nothing here chooses a device; only the user does. A row is selected only when it is the
/// chosen microphone, or System Default when none is chosen, so a virtual device is never
/// selected on the user's behalf.
public struct MicrophonePickerList: Sendable, Equatable {
    /// One selectable entry.
    public struct Row: Identifiable, Sendable, Equatable {
        /// Which part of the list a row belongs to.
        public enum Kind: Sendable, Equatable {
            /// Follows the system default input.
            case systemDefault
            /// A connected physical microphone.
            case microphone
            /// A connected virtual or aggregate device.
            case otherDevice
            /// The chosen microphone, which is not connected. Capture uses a fallback meanwhile.
            case disconnected
        }

        /// The device UID, or `nil` for System Default.
        public let uid: String?
        public let title: String
        public let kind: Kind
        public let isSelected: Bool

        public var id: String { uid ?? "" }
    }

    public let systemDefault: Row
    /// Physical microphones, then the chosen microphone when it is not connected and was not
    /// last seen as a virtual device.
    public let microphones: [Row]
    /// Virtual and aggregate devices: all of them when shown, otherwise only a chosen one. A
    /// chosen one that is not connected comes last.
    public let otherDevices: [Row]

    /// - Parameters:
    ///   - snapshot: the connected devices and the system default input.
    ///   - selectedUID: the chosen microphone's UID; `nil` follows the system default.
    ///   - showVirtualDevices: the *Show other devices* setting (`showVirtualInputDevices`).
    ///   - lastSeenChoice: the chosen microphone as it was when last connected, if that is known
    ///     (only its UID is saved). It names a disconnected choice and keeps a virtual one among
    ///     the other devices. Ignored unless its id is `selectedUID`.
    public init(
        snapshot: InputDeviceSnapshot,
        selectedUID: String?,
        showVirtualDevices: Bool,
        lastSeenChoice: AudioInputDevice? = nil
    ) {
        systemDefault = Row(
            uid: nil,
            title: Self.systemDefaultTitle(in: snapshot),
            kind: .systemDefault,
            isSelected: selectedUID == nil
        )
        func row(_ device: AudioInputDevice) -> Row {
            Row(
                uid: device.id,
                title: device.name,
                kind: device.isVirtual ? .otherDevice : .microphone,
                isSelected: device.id == selectedUID
            )
        }
        var microphones = snapshot.physicalDevices.map(row)
        var otherDevices = snapshot.connected
            .filter { $0.isVirtual && (showVirtualDevices || $0.id == selectedUID) }
            .map(row)
        if let selectedUID, snapshot.device(withID: selectedUID) == nil {
            let lastSeen = lastSeenChoice?.id == selectedUID ? lastSeenChoice : nil
            let disconnected = Row(
                uid: selectedUID,
                title: lastSeen.map { "\($0.name) (disconnected)" } ?? "Disconnected microphone",
                kind: .disconnected,
                isSelected: true
            )
            if lastSeen?.isVirtual == true {
                otherDevices.append(disconnected)
            } else {
                microphones.append(disconnected)
            }
        }
        self.microphones = microphones
        self.otherDevices = otherDevices
    }

    /// Every row in picker order.
    public var rows: [Row] { [systemDefault] + microphones + otherDevices }

    /// The row a picker shows as its current value. There is always exactly one.
    public var selectedRow: Row {
        rows.first(where: \.isSelected) ?? systemDefault
    }

    /// "System Default (name)", naming the device ``InputDevicePolicy`` opens for System Default
    /// at start, or plain "System Default" when nothing can be opened.
    static func systemDefaultTitle(in snapshot: InputDeviceSnapshot) -> String {
        guard let choice = try? InputDevicePolicy.deviceToOpen(selectedUID: nil, previous: nil, in: snapshot) else {
            return "System Default"
        }
        return "System Default (\(choice.device.name))"
    }
}
