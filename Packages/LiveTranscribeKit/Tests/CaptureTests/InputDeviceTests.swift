@preconcurrency import AVFoundation
@testable import Capture
import Foundation
import Shared
import Testing

/// Reads the real microphone list, so it holds with any hardware, including none.
@Suite("Input devices")
struct InputDeviceTests {
    private let devices = SystemInputDevices(store: AppSettingsStore(suiteName: "LiveTranscribeTests.\(UUID().uuidString)"))

    @Test func everyListedMicrophoneCanBeOpenedByItsID() {
        let listed = devices.availableDevices()
        for device in listed {
            #expect(!device.id.isEmpty)
            #expect(!device.name.isEmpty)
            #expect(AVCaptureDevice(uniqueID: device.id) != nil, "the picker only offers devices capture can open")
        }
        #expect(listed == listed.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
    }

    @Test func startingWithADisconnectedMicrophoneFailsClearly() async {
        let source = CaptureSessionSource(
            restartPolicy: CaptureRestartPolicy(maxAttempts: 1, delaySeconds: 0, maxRestartsPerMinute: 1),
            inputDeviceUID: "LiveTranscribe.no-such-device"
        )
        await #expect(throws: CaptureError.inputDeviceUnavailable) {
            _ = try await source.start()
        }
        await source.stop()
    }
}
