@preconcurrency import AVFoundation
import Foundation

/// The input hardware at one moment: what ``InputDevicePolicy`` decides from.
public struct InputDeviceSnapshot: Sendable, Equatable {
    /// Devices capture can open, in the catalog's order (sorted by name for the system catalog).
    public let connected: [AudioInputDevice]
    /// The system default input, only when it is one of `connected`.
    public let systemDefault: AudioInputDevice?

    /// A default that is not in `connected` is dropped. The two lists come from separate calls,
    /// so a device can briefly be the default before it can be opened; treating it as absent
    /// means the next change, once it can be opened, still counts as a new default.
    public init(connected: [AudioInputDevice], systemDefault: AudioInputDevice?) {
        self.connected = connected
        self.systemDefault = systemDefault.flatMap { candidate in connected.first { $0.id == candidate.id } }
    }

    /// The connected device with this UID.
    func device(withID id: String) -> AudioInputDevice? {
        connected.first { $0.id == id }
    }

    /// Connected devices that are physical microphones, in order.
    var physicalDevices: [AudioInputDevice] {
        connected.filter { !$0.isVirtual }
    }
}

/// Reads the input hardware and reports when it changes. ``CaptureSessionSource`` decides which
/// microphone to open from it; tests replace it with a fake.
public protocol InputDeviceCatalog: Sendable {
    /// The connected devices and the system default, read now.
    func snapshot() -> InputDeviceSnapshot
    /// Yields when a device connects or disconnects or the default input changes. Several
    /// yields may describe one change; ending the iteration stops observing.
    func changes() -> AsyncStream<Void>
}

/// ``InputDeviceCatalog`` backed by AVFoundation's microphone list, with each device's transport
/// type read from Core Audio.
///
/// Devices are listed by the same API ``CaptureSessionSource`` opens them with, so every entry
/// can be captured from. Their ids are `AVCaptureDevice.uniqueID`s, which on macOS are Core Audio
/// device UIDs.
public struct SystemInputDeviceCatalog: InputDeviceCatalog {
    public init() {}

    /// Connected input devices, sorted by name, virtual ones included.
    public func connectedDevices() -> [AudioInputDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified)
            .devices
            .map(Self.device(from:))
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The input selected in System Settings, as AVFoundation reports it.
    public func systemDefaultDevice() -> AudioInputDevice? {
        AVCaptureDevice.default(for: .audio).map(Self.device(from:))
    }

    public func snapshot() -> InputDeviceSnapshot {
        InputDeviceSnapshot(connected: connectedDevices(), systemDefault: systemDefaultDevice())
    }

    public func changes() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let observation = DeviceChangeObservation { continuation.yield() }
        continuation.onTermination = { _ in observation.cancel() }
        return stream
    }

    /// Core Audio is asked for the transport type by UID; AVFoundation's `transportType` (the same
    /// Core Audio constant for audio devices) is the fallback if the UID lookup fails.
    static func device(from captureDevice: AVCaptureDevice) -> AudioInputDevice {
        let transportType = AudioTransport.transportType(forUID: captureDevice.uniqueID)
            ?? UInt32(bitPattern: captureDevice.transportType)
        return AudioInputDevice(
            id: captureDevice.uniqueID,
            name: captureDevice.localizedName,
            isVirtual: AudioTransport.isVirtual(transportType: transportType)
        )
    }
}
