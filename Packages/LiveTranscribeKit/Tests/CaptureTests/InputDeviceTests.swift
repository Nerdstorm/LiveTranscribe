@preconcurrency import AVFoundation
@testable import Capture
import Foundation
import Shared
import Testing

/// Reads the real microphone list, so it holds with any hardware, including none. Nothing here
/// opens a microphone; what capture does with a missing or disconnected device is covered with
/// fakes in `CaptureSessionSourceTests`.
@Suite("Input devices")
struct InputDeviceTests {
    private let devices = SystemInputDevices(store: AppSettingsStore(suiteName: "LiveTranscribeTests.\(UUID().uuidString)"))

    @Test func everyListedMicrophoneCanBeOpenedByItsID() {
        let listed = devices.snapshot().connected
        for device in listed {
            #expect(!device.id.isEmpty)
            #expect(!device.name.isEmpty)
            #expect(AVCaptureDevice(uniqueID: device.id) != nil, "the picker only offers devices capture can open")
        }
        #expect(listed == listed.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
    }

    @Test func theSnapshotDefaultIsAlwaysAListedDevice() {
        let snapshot = SystemInputDeviceCatalog().snapshot()
        if let systemDefault = snapshot.systemDefault {
            #expect(snapshot.connected.contains(systemDefault))
        }
    }

    @Test func coreAudioAgreesWithAVFoundationOnEveryTransport() throws {
        for device in devices.snapshot().connected {
            let captureDevice = try #require(AVCaptureDevice(uniqueID: device.id))
            let avFoundation = UInt32(bitPattern: captureDevice.transportType)
            #expect(AudioTransport.transportType(forUID: device.id) == avFoundation, "the UID lookup finds the same device")
            #expect(device.isVirtual == AudioTransport.isVirtual(transportType: avFoundation))
        }
    }

    @Test func anUnknownUIDHasNoTransportType() {
        #expect(AudioTransport.transportType(forUID: "LiveTranscribe.no-such-device") == nil)
    }
}
