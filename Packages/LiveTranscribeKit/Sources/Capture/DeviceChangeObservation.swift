import CoreAudio
import Foundation
import Shared

/// Core Audio listeners for device connects and disconnects and for default-input changes. The
/// listeners are removed by ``cancel()``.
final class DeviceChangeObservation: @unchecked Sendable {
    // @unchecked: every stored property is immutable after init; Core Audio invokes `block` on `queue`.
    private static let selectors = [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice]

    private let queue = DispatchQueue(label: "LiveTranscribe.AudioDevices")
    private let block: AudioObjectPropertyListenerBlock

    init(onChange: @escaping @Sendable () -> Void) {
        block = { _, _ in onChange() }
        for selector in Self.selectors {
            var address = Self.address(selector)
            let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
            if status != noErr {
                Log.capture.error("Could not observe audio devices (OSStatus \(status))")
            }
        }
    }

    func cancel() {
        for selector in Self.selectors {
            var address = Self.address(selector)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}
