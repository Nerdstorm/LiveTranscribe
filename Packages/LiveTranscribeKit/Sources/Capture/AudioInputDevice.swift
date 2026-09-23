import Foundation

/// A microphone that capture can use. `id` is the Core Audio device UID, which stays the same
/// across reconnects (the numeric `AudioDeviceID` does not).
public struct AudioInputDevice: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    /// A virtual, aggregate or auto-aggregate device rather than one physical microphone: a
    /// meeting app's loopback driver, a routing tool, or a combination of other devices. Capture
    /// never moves to one of these on its own (decision M1), and the picker hides them unless
    /// asked, because they often carry other apps' audio or silence instead of the user's voice.
    public let isVirtual: Bool

    /// `isVirtual` defaults to `false` so code that only knows an id and a name keeps compiling.
    public init(id: String, name: String, isVirtual: Bool = false) {
        self.id = id
        self.name = name
        self.isVirtual = isVirtual
    }
}

/// Lists the connected microphones and remembers which one to capture from.
public protocol InputDeviceSelecting: Sendable {
    /// Connected input devices, sorted by name. Virtual devices are included and flagged with
    /// ``AudioInputDevice/isVirtual``; hiding them is the picker's choice.
    func availableDevices() -> [AudioInputDevice]
    /// Name of the current system default input, if there is one.
    func systemDefaultName() -> String?
    /// The chosen device's UID, or `nil` to follow the system default input.
    var selectedDeviceUID: String? { get }
    /// Persists the choice; it applies the next time capture starts.
    func select(_ uid: String?)
    /// Yields when a device connects or disconnects, or the system default input changes.
    func changes() -> AsyncStream<Void>
}
