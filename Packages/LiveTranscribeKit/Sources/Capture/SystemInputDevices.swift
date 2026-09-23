import Foundation
import Shared

/// ``InputDeviceSelecting`` backed by ``SystemInputDeviceCatalog``, with the choice saved
/// through ``AppSettingsStore``.
///
/// The list is the one ``CaptureSessionSource`` opens devices from, so every entry in the picker
/// can be captured from. Virtual devices are listed and flagged; ``MicrophonePickerList``
/// decides whether a picker shows them.
public struct SystemInputDevices: InputDeviceSelecting {
    private let store: AppSettingsStore
    private let catalog = SystemInputDeviceCatalog()

    public init(store: AppSettingsStore) {
        self.store = store
    }

    public func snapshot() -> InputDeviceSnapshot {
        catalog.snapshot()
    }

    public var selectedDeviceUID: String? {
        store.inputDeviceUID
    }

    public func select(_ uid: String?) {
        store.setInputDeviceUID(uid)
        Log.capture.info("Microphone set to \(uid ?? "system default", privacy: .private)")
    }

    public func changes() -> AsyncStream<Void> {
        catalog.changes()
    }
}
