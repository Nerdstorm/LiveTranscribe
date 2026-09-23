@testable import Dictation
import Foundation
import Shared
import Testing

/// Notices raised during a dictation (a change of microphone, a press while processing) show
/// under *Listening* and again once it ends; notices at the end of a dictation follow one
/// another instead of hiding each other.
@MainActor
@Suite("DictationController notices")
struct DictationNoticeFlowTests {
    private static let fallback = DictationNotice.microphone("The chosen microphone isn't connected. Using MacBook Pro Microphone instead.")

    /// A harness whose notices stay up only briefly, so a test can watch them follow each other.
    private func briefNotices(_ configure: (inout AppSettings) -> Void = { _ in }) -> Harness {
        Harness {
            $0.dictation.noticeSeconds = 0.05
            configure(&$0)
        }
    }

    @Test func aMicrophoneNoticeDuringARecordingShowsUnderListeningAndAgainAfterIt() async {
        let h = Harness()
        h.controller.start()
        await h.hold(milliseconds: 500)
        h.controller.showMicrophoneNotice(Self.fallback.message)
        #expect(h.controller.progressNotice == Self.fallback, "shown under Listening")
        #expect(h.controller.notice == nil)

        await h.release()
        #expect(await h.delivery.inserted == ["Ship it on friday."])
        #expect(h.controller.phase == .idle)
        #expect(h.controller.notice == Self.fallback, "an insertion without a notice of its own does not clear it")
        #expect(h.controller.progressNotice == nil)
    }

    @Test func aMicrophoneNoticeFollowsTheDictationsOwnNotice() async {
        let h = briefNotices()
        await h.delivery.set(result: .copiedToClipboard)
        h.controller.start()
        await h.hold(milliseconds: 500)
        h.controller.showMicrophoneNotice(Self.fallback.message)
        await h.release()

        #expect(h.controller.notice == .copiedToClipboard(app: "Notes"), "what needs doing comes first")
        #expect(await eventually { h.controller.notice == Self.fallback })
        #expect(await eventually { h.controller.notice == nil })
    }

    @Test func aCancelledDictationStillShowsTheMicrophoneNotice() async {
        let h = briefNotices()
        h.controller.start()
        await h.hold(milliseconds: 500)
        h.controller.showMicrophoneNotice(Self.fallback.message)
        h.controller.handle(.escape)
        await h.controller.settle()

        #expect(h.controller.notice == .cancelled)
        #expect(await eventually { h.controller.notice == Self.fallback })
    }

    @Test func aProgressNoticeGivesTheHintBackAfterTheNoticeTimeButIsStillShownAfterwards() async {
        let h = briefNotices()
        h.controller.start()
        await h.hold(milliseconds: 500)
        h.controller.showMicrophoneNotice(Self.fallback.message)
        #expect(await eventually { h.controller.progressNotice == nil })
        #expect(h.controller.phase == .recording(handsFree: false))

        await h.release()
        #expect(h.controller.notice == Self.fallback)
    }

    @Test func onlyTheLatestMicrophoneNoticeIsShownAfterwards() async {
        let h = briefNotices()
        h.controller.start()
        await h.hold(milliseconds: 500)
        h.controller.showMicrophoneNotice("Using MacBook Pro Microphone.")
        h.controller.showMicrophoneNotice("Now using AirPods.")
        #expect(h.controller.progressNotice == .microphone("Now using AirPods."))

        await h.release()
        #expect(h.controller.notice == .microphone("Now using AirPods."))
        #expect(await eventually { h.controller.notice != .microphone("Now using AirPods.") })
        #expect(h.controller.notice == nil, "the earlier microphone is no longer in use, so it is not shown")
    }

    @Test func aNoticeStillWaitingIsDroppedWhenTheNextDictationStarts() async {
        // Long enough for the next recording to start while the first notice is up.
        let h = Harness { $0.dictation.noticeSeconds = 0.3 }
        await h.delivery.set(result: .copiedToClipboard)
        h.controller.start()
        await h.hold(milliseconds: 500)
        h.controller.showMicrophoneNotice(Self.fallback.message)
        await h.release()
        #expect(h.controller.notice == .copiedToClipboard(app: "Notes"))

        await h.hold(milliseconds: 500)
        #expect(h.controller.phase == .recording(handsFree: false))
        #expect(await eventually { h.controller.notice != .copiedToClipboard(app: "Notes") })
        #expect(h.controller.notice == nil, "the waiting notice was about the last dictation")
        h.controller.cancel()
        await h.controller.settle()
    }

    @Test func aMicrophoneNoticeBetweenDictationsShowsAtOnce() async {
        let h = Harness()
        h.controller.start()
        h.controller.showMicrophoneNotice(Self.fallback.message)
        #expect(h.controller.notice == Self.fallback)
        #expect(h.controller.progressNotice == nil)
    }

    // MARK: - The recording's length limit

    @Test func aTruncatedRecordingSaysSoAtItsLimit() async {
        let h = Harness { $0.dictation.maxRecordingSeconds = 1 }
        h.controller.start()
        await h.hold(milliseconds: 1_500)
        await h.release()
        #expect(await h.delivery.inserted.count == 1)
        #expect(h.controller.notice == .recordingTruncated(seconds: 1))
    }

    @Test func aTruncatedRecordingLeftOnTheClipboardSaysSoFirst() async {
        let h = briefNotices { $0.dictation.maxRecordingSeconds = 1 }
        await h.delivery.set(result: .copiedToClipboard)
        h.controller.start()
        await h.hold(milliseconds: 1_500)
        await h.release()

        #expect(h.controller.notice == .copiedToClipboard(app: "Notes"), "the text waits for ⌘V")
        #expect(await eventually { h.controller.notice == .recordingTruncated(seconds: 1) })
    }
}

/// What each notice says, and which one a recording that missed some speech gets.
@MainActor
@Suite("DictationNotice")
struct DictationNoticeTests {
    @Test("Durations are written in seconds under a minute, then minutes and seconds", arguments: [
        (10, "10 s"), (30, "30 s"), (59, "59 s"), (60, "1 min"), (90, "1 min 30 s"), (300, "5 min"), (1_800, "30 min"),
    ])
    func duration(seconds: Int, expected: String) {
        #expect(DictationNotice.duration(seconds: seconds) == expected)
    }

    @Test func theLengthLimitIsNamedExactly() {
        #expect(DictationNotice.recordingTruncated(seconds: 30).message == "Recording stopped at 30 s; the rest wasn't heard")
        #expect(DictationNotice.recordingTruncated(seconds: 90).message == "Recording stopped at 1 min 30 s; the rest wasn't heard")
        #expect(DictationNotice.captureStoppedEarly(afterSeconds: 12).message == "The microphone stopped after 12 s; the rest wasn't heard")
        #expect(DictationNotice.captureStoppedEarly(afterSeconds: 12).isProblem)
    }

    private func recording(ms: Int, truncated: Bool = false, failure: String? = nil) -> DictationRecorder.Recording {
        DictationRecorder.Recording(
            samples: [Float](repeating: 0, count: AudioFormat.samples(forMilliseconds: ms)), truncated: truncated, failure: failure
        )
    }

    @Test func aCompleteRecordingNeedsNoNotice() {
        #expect(DictationController.notice(for: recording(ms: 2_000), limitSeconds: 300) == nil)
    }

    @Test func theLimitComesBeforeAFailureAfterIt() {
        let notice = DictationController.notice(for: recording(ms: 2_000, truncated: true, failure: "gone"), limitSeconds: 300)
        #expect(notice == .recordingTruncated(seconds: 300))
    }

    @Test("A microphone that stopped early is timed to the nearest second, never 0", arguments: [
        (200, 1), (1_499, 1), (1_500, 2), (12_000, 12),
    ])
    func stoppedEarly(ms: Int, seconds: Int) {
        let notice = DictationController.notice(for: recording(ms: ms, failure: "gone"), limitSeconds: 300)
        #expect(notice == .captureStoppedEarly(afterSeconds: seconds))
    }
}
