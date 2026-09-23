@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import Shared

/// Core Audio listeners for device connects and disconnects and for default-input changes, plus
/// AVFoundation's own connect and disconnect notifications for audio devices. Everything is
/// removed by ``cancel()``.
///
/// AVFoundation learns about a new device from Core Audio too, so it can lag the Core Audio
/// listener. Its notifications give one more change once it has caught up, which is when a
/// newly connected microphone can actually be opened.
final class DeviceChangeObservation: @unchecked Sendable {
    // @unchecked: every stored property is immutable after init; Core Audio invokes `block` on
    // `queue`, and NotificationCenter removal is thread-safe.
    private static let selectors = [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice]
    private static let notifications = [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification]

    private let queue = DispatchQueue(label: "LiveTranscribe.AudioDevices")
    private let block: AudioObjectPropertyListenerBlock
    private let observers: [any NSObjectProtocol]

    init(onChange: @escaping @Sendable () -> Void) {
        block = { _, _ in onChange() }
        for selector in Self.selectors {
            var address = Self.address(selector)
            let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
            if status != noErr {
                Log.capture.error("Could not observe audio devices (OSStatus \(status))")
            }
        }
        observers = Self.notifications.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { note in
                guard let device = note.object as? AVCaptureDevice, device.hasMediaType(.audio) else { return }
                onChange()
            }
        }
    }

    func cancel() {
        for selector in Self.selectors {
            var address = Self.address(selector)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
        }
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
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
