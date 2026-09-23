import Foundation
import Shared

/// ``InputDeviceSelecting`` backed by ``SystemInputDeviceCatalog``, with the choice saved
/// through ``AppSettingsStore``.
///
/// The list is the one ``CaptureSessionSource`` opens devices from, so every entry in the picker
/// can be captured from. Virtual devices are listed and flagged; the picker decides whether to
/// show them.
public struct SystemInputDevices: InputDeviceSelecting {
    private let store: AppSettingsStore
    private let catalog = SystemInputDeviceCatalog()

    public init(store: AppSettingsStore) {
        self.store = store
    }

    public func availableDevices() -> [AudioInputDevice] {
        catalog.connectedDevices()
    }

    public func systemDefaultName() -> String? {
        catalog.systemDefaultDevice()?.name
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
