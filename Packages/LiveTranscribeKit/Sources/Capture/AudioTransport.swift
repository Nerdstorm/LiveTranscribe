import CoreAudio
import Foundation
import Shared

/// Reads how a device is connected (built in, USB, Bluetooth, virtual, aggregate…) from Core
/// Audio, to tell physical microphones from virtual ones.
enum AudioTransport {
    /// Transport types that are not one physical microphone. Everything else, including
    /// `kAudioDeviceTransportTypeUnknown`, counts as physical: a device that does not say what it
    /// is gets the benefit of the doubt rather than disappearing from the picker.
    static let virtualTransportTypes: Set<UInt32> = [
        kAudioDeviceTransportTypeVirtual,
        kAudioDeviceTransportTypeAggregate,
        kAudioDeviceTransportTypeAutoAggregate,
    ]

    /// Whether a device with this transport type is virtual (see ``AudioInputDevice/isVirtual``).
    static func isVirtual(transportType: UInt32) -> Bool {
        virtualTransportTypes.contains(transportType)
    }

    /// The transport type of the device with this Core Audio UID, or `nil` when Core Audio does
    /// not know the UID (the device has gone) or will not say.
    static func transportType(forUID uid: String) -> UInt32? {
        guard let device = deviceID(forUID: uid) else { return nil }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transportType: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transportType)
        guard status == noErr else {
            Log.capture.error("Could not read a device's transport type (OSStatus \(status))")
            return nil
        }
        return transportType
    }

    /// Translates a UID into the current numeric `AudioObjectID`, which changes across reconnects.
    private static func deviceID(forUID uid: String) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var qualifier: CFString = uid as CFString
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &qualifier) { qualifierPointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<CFString>.size),
                qualifierPointer,
                &size,
                &device
            )
        }
        guard status == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }
}
