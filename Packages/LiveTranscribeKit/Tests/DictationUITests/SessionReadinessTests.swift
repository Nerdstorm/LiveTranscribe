import Capture
import Dictation
@testable import DictationUI
import Session
import Testing

@Suite("Dictation readiness from the session")
struct SessionReadinessTests {
    @Test("Each session phase maps to a readiness", arguments: [
        (SessionPhase.notLoaded, DictationReadiness.modelsLoading),
        (.loading, .modelsLoading),
        (.ready, .ready),
        (.listening, .liveTranscriptRunning),
        (.stopping, .liveTranscriptRunning),
        (.failed(.modelLoadFailed(model: "stt", message: "offline")), .modelsUnavailable("offline")),
        (.failed(.microphonePermissionDenied), .ready),
        (.failed(.audioCaptureFailed(message: "gone")), .ready),
        (.failed(.persistenceFailed(message: "disk full")), .ready),
    ])
    func mapping(phase: SessionPhase, readiness: DictationReadiness) {
        #expect(DictationReadiness(sessionPhase: phase) == readiness)
    }
}

@Suite("CaptureNoticeFilter")
struct CaptureNoticeFilterTests {
    @Test func aRepeatedNoticeIsShownOnce() {
        var filter = CaptureNoticeFilter()
        let notice = CaptureNotice.skippedVirtualDefault(virtual: "Teams Audio", using: "MacBook Pro Microphone")
        #expect(show(notice, with: &filter) == true)
        #expect(show(notice, with: &filter) == false)
        #expect(show(notice, with: &filter) == false)
    }

    @Test func aDifferentNoticeIsShownAndTheFirstCanReturn() {
        var filter = CaptureNoticeFilter()
        let first = CaptureNotice.switchedDevice(name: "AirPods")
        let second = CaptureNotice.returnedToSelected(name: "Yeti")
        #expect(show(first, with: &filter) == true)
        #expect(show(second, with: &filter) == true)
        #expect(show(first, with: &filter) == true)
    }

    @Test func aDeviceChangeMakesTheNoticeNewsAgain() {
        var filter = CaptureNoticeFilter()
        let notice = CaptureNotice.fellBackToDefault(missing: nil, using: "MacBook Pro Microphone")
        #expect(show(notice, with: &filter) == true)
        filter.devicesChanged()
        #expect(show(notice, with: &filter) == true)
    }

    private func show(_ notice: CaptureNotice, with filter: inout CaptureNoticeFilter) -> Bool {
        filter.shouldShow(notice)
    }
}
