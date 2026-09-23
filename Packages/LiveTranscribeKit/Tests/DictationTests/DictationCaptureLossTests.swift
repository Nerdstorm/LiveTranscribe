@testable import Dictation
import Foundation
import Shared
import Testing

/// The microphone stopping partway through a dictation (a headset that disconnects with nothing
/// to fall back to): the dictation ends at once with what was heard, and says so.
@MainActor
@Suite("DictationController capture loss")
struct DictationCaptureLossTests {
    @Test func aMicrophoneThatStopsMidRecordingEndsItWithWhatWasHeard() async throws {
        let h = Harness()
        h.controller.start()
        await h.hold(milliseconds: 500)
        await h.source.fail(CaptureFailed())

        #expect(await eventually { h.controller.phase == .idle }, "no longer Listening to nothing")
        await h.controller.settle()
        #expect(await h.delivery.inserted == ["Ship it on friday."])
        #expect(h.controller.notice == .captureStoppedEarly(afterSeconds: 1))
        let saved = try await h.history.all()
        #expect(saved.first?.captureFailure == "microphone unplugged")

        await h.release()
        #expect(await h.delivery.inserted.count == 1, "the release of the held key does nothing more")
        #expect(h.controller.phase == .idle)
        #expect(await h.source.starts == 1)
    }

    @Test func aHandsFreeDictationEndsWithoutAPress() async {
        let h = Harness()
        h.controller.start()
        await h.hold(milliseconds: 100)
        await h.release()
        h.controller.handle(.pressed)
        h.controller.handle(.released)
        await h.controller.settle()
        #expect(h.controller.phase == .recording(handsFree: true))
        await h.source.push([Float](repeating: 0.1, count: AudioFormat.samples(forMilliseconds: 400)))
        try? await Task.sleep(for: .milliseconds(20))

        await h.source.fail(CaptureFailed())
        #expect(await eventually { h.controller.phase == .idle })
        await h.controller.settle()
        #expect(await h.delivery.inserted == ["Ship it on friday."])
        #expect(h.controller.notice == .captureStoppedEarly(afterSeconds: 1))
    }

    @Test func tooLittleHeardBeforeTheMicrophoneStoppedIsTheFailure() async {
        let h = Harness { $0.dictation.minUtteranceMs = 300 }
        h.controller.start()
        await h.hold(milliseconds: 100)
        await h.source.fail(CaptureFailed())

        #expect(await eventually { h.controller.phase == .idle })
        await h.controller.settle()
        #expect(h.controller.notice == .captureFailed("microphone unplugged"), "not \"didn't catch that\"")
        #expect(await h.transcriber.calls == 0)
    }

    @Test func nothingTranscribedBeforeTheMicrophoneStoppedIsTheFailure() async {
        let h = Harness(transcript: "")
        h.controller.start()
        await h.hold(milliseconds: 500)
        await h.source.fail(CaptureFailed())

        #expect(await eventually { h.controller.phase == .idle })
        await h.controller.settle()
        #expect(h.controller.notice == .captureFailed("microphone unplugged"))
        #expect(await h.delivery.inserted.isEmpty)
    }

    @Test func aLateReportDoesNotEndARecordingWhoseMicrophoneWorks() async {
        let h = Harness()
        h.controller.start()
        await h.hold(milliseconds: 500)

        await h.controller.endRecordingWithoutCapture()
        #expect(h.controller.phase == .recording(handsFree: false))

        await h.release()
        #expect(await h.delivery.inserted == ["Ship it on friday."])
        #expect(h.controller.notice == nil)
    }
}
