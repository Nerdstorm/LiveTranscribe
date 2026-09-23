import Foundation

/// A microphone that capture can use. `id` is the Core Audio device UID, which stays the same
/// across reconnects (the numeric `AudioDeviceID` does not).
public struct AudioInputDevice: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    /// A virtual, aggregate or auto-aggregate device rather than one physical microphone: a
    /// meeting app's loopback driver, a routing tool, or a combination of other devices. Capture
    /// never moves to one of these on its own (decision M1), and the pickers hide them unless
    /// asked (``MicrophonePickerList``), because they often carry other apps' audio or silence
    /// instead of the user's voice.
    public let isVirtual: Bool

    /// `isVirtual` defaults to `false` so code that only knows an id and a name keeps compiling.
    public init(id: String, name: String, isVirtual: Bool = false) {
        self.id = id
        self.name = name
        self.isVirtual = isVirtual
    }
}

/// Lists the input hardware, as ``InputDeviceCatalog`` does, and remembers which microphone to
/// capture from. The pickers read it; which devices they list is ``MicrophonePickerList``'s rule.
public protocol InputDeviceSelecting: InputDeviceCatalog {
    /// The chosen device's UID, or `nil` to follow the system default input.
    var selectedDeviceUID: String? { get }
    /// Persists the choice; it applies the next time capture starts.
    func select(_ uid: String?)
}
