@preconcurrency import AVFoundation
import Foundation
import Shared

/// ``InputDeviceSelecting`` backed by AVFoundation's microphone list, with the choice saved
/// through ``AppSettingsStore``.
///
/// Devices are listed by the same API ``CaptureSessionSource`` opens them with, so every entry
/// in the picker can be captured from. Their ids are `AVCaptureDevice.uniqueID`s, which on
/// macOS are Core Audio device UIDs.
public struct SystemInputDevices: InputDeviceSelecting {
    private let store: AppSettingsStore

    public init(store: AppSettingsStore) {
        self.store = store
    }

    public func availableDevices() -> [AudioInputDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified)
            .devices
            .map { AudioInputDevice(id: $0.uniqueID, name: $0.localizedName) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func systemDefaultName() -> String? {
        AVCaptureDevice.default(for: .audio)?.localizedName
    }

    public var selectedDeviceUID: String? {
        store.inputDeviceUID
    }

    public func select(_ uid: String?) {
        store.setInputDeviceUID(uid)
        Log.capture.info("Microphone set to \(uid ?? "system default", privacy: .private)")
    }

    public func changes() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let observation = DeviceChangeObservation { continuation.yield() }
        continuation.onTermination = { _ in observation.cancel() }
        return stream
    }
}
