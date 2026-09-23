import Foundation

/// A microphone that capture can use. `id` is the Core Audio device UID, which stays the same
/// across reconnects (the numeric `AudioDeviceID` does not).
public struct AudioInputDevice: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// Lists the connected microphones and remembers which one to capture from.
public protocol InputDeviceSelecting: Sendable {
    /// Connected input devices, sorted by name.
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
