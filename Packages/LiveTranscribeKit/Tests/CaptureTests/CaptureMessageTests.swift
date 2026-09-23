@testable import Capture
import CoreAudio
import Testing

@Suite("Capture notices and errors")
struct CaptureMessageTests {
    @Test("Notices read as plain sentences", arguments: [
        (CaptureNotice.switchedDevice(name: "Yeti"), "Now using Yeti."),
        (.fellBackToDefault(missing: "OpenComm2", using: "MacBook Pro Microphone"),
         "OpenComm2 isn't connected. Using MacBook Pro Microphone instead."),
        (.fellBackToDefault(missing: nil, using: "MacBook Pro Microphone"),
         "The chosen microphone isn't connected. Using MacBook Pro Microphone instead."),
        (.keptDevice(current: "Yeti", ignoredVirtual: "Microsoft Teams Audio"),
         "Still using Yeti. The new default input, Microsoft Teams Audio, is a virtual device, so it isn't used unless you choose it."),
        (.skippedVirtualDefault(virtual: "Microsoft Teams Audio", using: "Yeti"),
         "Using Yeti. The default input, Microsoft Teams Audio, is a virtual device, so it isn't used unless you choose it."),
        (.returnedToSelected(name: "OpenComm2"), "OpenComm2 is connected again and in use."),
    ])
    func noticeMessages(notice: CaptureNotice, expected: String) {
        #expect(notice.message == expected)
    }

    @Test("The loggable kind carries no device name", arguments: [
        CaptureNotice.switchedDevice(name: "Secret Mic"),
        .fellBackToDefault(missing: "Secret Mic", using: "Secret Mic"),
        .keptDevice(current: "Secret Mic", ignoredVirtual: "Secret Mic"),
        .skippedVirtualDefault(virtual: "Secret Mic", using: "Secret Mic"),
        .returnedToSelected(name: "Secret Mic"),
    ])
    func noticeKindIsPrivacySafe(notice: CaptureNotice) {
        #expect(!notice.kind.isEmpty)
        #expect(!notice.kind.contains("Secret"))
    }

    @Test("Every error explains itself", arguments: [
        CaptureError.noInputDevice,
        .unsupportedFormat("8-bit"),
        .startFailed("busy"),
        .restartFailed(attempts: 3),
        .inputDeviceUnavailable,
        .tooManyRestarts(restarts: 6),
        .alreadyRunning,
        .unreadableFile("a.wav"),
    ])
    func errorDescriptions(error: CaptureError) {
        let description = error.errorDescription ?? ""
        #expect(description.count > 20, "a sentence, not a code")
        #expect(description.first?.isUppercase == true)
    }

    @Test func aMissingChoiceWithNothingToFallBackToSaysWhatToDo() {
        #expect(CaptureError.inputDeviceUnavailable.errorDescription
            == "The selected microphone isn't connected and no other microphone can be used instead. "
            + "Connect it, or choose another one from the microphone menu.")
    }

    @Test("Recovery reports a missing device over a generic failure", arguments: [
        (CaptureError.noInputDevice as (any Error)?, CaptureError.noInputDevice),
        (CaptureError.inputDeviceUnavailable, .inputDeviceUnavailable),
        (CaptureError.startFailed("busy"), .restartFailed(attempts: 2)),
        (nil, .restartFailed(attempts: 2)),
    ])
    func finalRecoveryError(lastError: (any Error)?, expected: CaptureError) {
        #expect(CaptureError.afterFailedRecovery(lastError: lastError, attempts: 2) == expected)
    }

    @Test("Virtual, aggregate and auto-aggregate transports are virtual", arguments: [
        (kAudioDeviceTransportTypeVirtual, true),
        (kAudioDeviceTransportTypeAggregate, true),
        (kAudioDeviceTransportTypeAutoAggregate, true),
        (kAudioDeviceTransportTypeBuiltIn, false),
        (kAudioDeviceTransportTypeUSB, false),
        (kAudioDeviceTransportTypeBluetooth, false),
        (kAudioDeviceTransportTypeBluetoothLE, false),
        (kAudioDeviceTransportTypeThunderbolt, false),
        (kAudioDeviceTransportTypeContinuityCaptureWired, false),
        (kAudioDeviceTransportTypeUnknown, false),
    ])
    func transportClassification(transportType: UInt32, isVirtual: Bool) {
        #expect(AudioTransport.isVirtual(transportType: transportType) == isVirtual)
    }

    @Test func existingCallersStillGetPhysicalDevices() {
        #expect(!AudioInputDevice(id: "a", name: "A").isVirtual)
    }
}
