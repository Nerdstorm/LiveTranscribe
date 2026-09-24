import Capture
import Cleanup
@testable import Dictation
import Foundation
import Hotkey
import Insertion
import Persistence
import Shared
import Snippets
import Testing
import Vocabulary

@MainActor
@Suite("DictationController")
struct DictationControllerTests {
    @Test func holdingTheKeyDictatesIntoTheFocusedField() async throws {
        let h = Harness()
        h.controller.start()
        #expect(h.controller.hotkeyState == .running(hotkey: HotkeyBinding.defaultDictation.displayName))

        await h.hold(milliseconds: 500)
        #expect(h.controller.phase == .recording(handsFree: false))
        #expect(h.hotkeys.capturingEscape, "Esc is captured while dictating")
        await h.release()

        #expect(await h.delivery.inserted == ["Ship it on friday."])
        #expect(h.controller.phase == .idle)
        #expect(!h.hotkeys.capturingEscape)
        #expect(h.controller.notice == nil)
        #expect(h.controller.lastText == "Ship it on friday.")
        let saved = try await h.history.all()
        #expect(saved.count == 1)
        #expect(saved.first?.rawText == "ship it on friday")
        #expect(saved.first?.cleanedText == "Ship it on friday.")
        #expect(saved.first?.delivery == "accessibility")
        #expect(saved.first?.appName == "Notes")
        #expect(saved.first?.cleanupLevel == "medium")
    }

    /// Whether the text may break across lines is the delivery's answer for the field dictated
    /// into, asked once the recording ends.
    @Test(arguments: [(true, "Thanks\nSee you soon."), (false, "Thanks see you soon.")])
    func aSpokenLineBreakFollowsTheDeliverysAnswer(allowed: Bool, inserted: String) async {
        let h = Harness(transcript: "thanks new line see you soon")
        await h.delivery.set(lineBreaks: allowed)
        h.controller.start()
        await h.hold(milliseconds: 500)
        await h.release()

        #expect(await h.delivery.inserted == [inserted])
        #expect(await h.delivery.lineBreakQuestions.map { $0.app } == [FakeFocus.app])
    }

    @Test func aSpaceSeparatesDictationFromTheWordBeforeTheCaret() async {
        let h = Harness()
        h.focus.set(FakeFocus.field(value: "Hello", secure: false))
        h.controller.start()
        await h.hold(milliseconds: 500)
        await h.release()
        #expect(await h.delivery.inserted == [" Ship it on friday."])
    }

    @Test func aLoneTapIsCancelledSilently() async throws {
        let h = Harness()
        h.controller.start()
        await h.hold(milliseconds: 100)
        await h.release()
        try await Task.sleep(for: .milliseconds(120))  // past the double-tap window
        await h.controller.settle()
        #expect(h.controller.phase == .idle)
        #expect(h.controller.notice == nil)
        #expect(await h.delivery.inserted.isEmpty)
        #expect(try await h.history.all().isEmpty)
    }

    @Test func aDoubleTapDictatesHandsFreeUntilTheNextPress() async {
        let h = Harness()
        h.controller.start()
        await h.hold(milliseconds: 100)
        await h.release()
        h.controller.handle(.pressed)
        await h.controller.settle()
        #expect(h.controller.phase == .recording(handsFree: true))
        h.controller.handle(.released)
        await h.source.push([Float](repeating: 0.1, count: AudioFormat.samples(forMilliseconds: 400)))
        try? await Task.sleep(for: .milliseconds(20))
        h.clock.advance(by: .seconds(3))
        #expect(h.controller.phase == .recording(handsFree: true), "releasing the second tap does not stop it")

        h.controller.handle(.pressed)
        await h.controller.settle()
        #expect(await h.delivery.inserted == ["Ship it on friday."])
        #expect(h.controller.phase == .idle)
    }

    @Test func escapeWhileRecordingCancels() async throws {
        let h = Harness()
        h.controller.start()
        await h.hold(milliseconds: 500)
        h.controller.handle(.escape)
        await h.controller.settle()
        #expect(h.controller.phase == .idle)
        #expect(h.controller.notice == .cancelled)
        await h.release()
        #expect(await h.delivery.inserted.isEmpty)
        #expect(try await h.history.all().isEmpty)
    }

    @Test func anotherKeyWhileHoldingCancelsSilently() async {
        let h = Harness()
        h.controller.start()
        await h.hold(milliseconds: 200)
        h.controller.handle(.otherKey)
        await h.controller.settle()
        #expect(h.controller.phase == .idle)
        #expect(h.controller.notice == nil)
    }

    @Test func tooShortARecordingIsNothingHeard() async {
        let h = Harness { $0.dictation.minUtteranceMs = 800 }
        h.controller.start()
        await h.hold(milliseconds: 400)
        await h.release()
        #expect(h.controller.notice == .nothingHeard)
        #expect(await h.transcriber.calls == 0)
    }

    @Test("Dictation refuses to start when it cannot run", arguments: [
        (DictationReadiness.modelsLoading, DictationNotice.modelsLoading),
        (.liveTranscriptRunning, .liveTranscriptRunning),
        (.modelsUnavailable("download failed"), .modelsUnavailable("download failed")),
    ])
    func refusesWhenNotReady(readiness: DictationReadiness, notice: DictationNotice) async {
        let h = Harness(readiness: readiness)
        h.controller.start()
        await h.hold(milliseconds: 500)
        #expect(h.controller.phase == .idle)
        #expect(h.controller.notice == notice)
        await h.release()
        #expect(await h.source.starts == 0, "the microphone never opened")
    }

    @Test func aPasswordFieldIsNeverTranscribedOrTyped() async {
        let h = Harness()
        h.focus.set(FakeFocus.field(value: "", secure: true))
        h.controller.start()
        await h.hold(milliseconds: 500)
        #expect(h.controller.phase == .idle, "the recording stops as soon as the field is known")
        await h.release()
        #expect(h.controller.notice == .secureField)
        #expect(await h.transcriber.calls == 0)
        #expect(await h.delivery.inserted.isEmpty)
    }

    @Test func aDeniedMicrophoneIsExplained() async {
        let h = Harness(microphone: .denied)
        h.controller.start()
        await h.hold(milliseconds: 500)
        #expect(h.controller.notice == .microphoneDenied)
    }

    @Test func textLeftOnTheClipboardIsExplained() async {
        let h = Harness()
        await h.delivery.set(result: .copiedToClipboard(.notAccepted))
        h.controller.start()
        await h.hold(milliseconds: 500)
        await h.release()
        #expect(h.controller.notice == .copiedToClipboard(app: "Notes"))
    }

    /// The app that was dictated into isn't blamed: Accessibility is on, so reopening is what's left.
    @Test func textLeftOnTheClipboardBecausePastingIsNotAllowedSaysToReopen() async {
        let h = Harness()
        await h.delivery.set(result: .copiedToClipboard(.pasteNotPermitted))
        h.controller.start()
        await h.hold(milliseconds: 500)
        await h.release()
        #expect(h.controller.notice == .pasteNotAllowed(needsReopen: true))
    }

    @Test func historyCanBeTurnedOff() async throws {
        let h = Harness { $0.dictation.historyEnabled = false }
        h.controller.start()
        await h.hold(milliseconds: 500)
        await h.release()
        #expect(await h.delivery.inserted.count == 1)
        #expect(try await h.history.all().isEmpty)
    }

    @Test func undoRestoresWhatWasSaidWithinTheWindow() async {
        let h = Harness(transcript: "um ship it on friday")
        h.controller.start()
        await h.hold(milliseconds: 500)
        await h.release()
        h.clock.advance(by: .seconds(10))
        h.controller.handle(.undo)
        await h.controller.settle()
        #expect(await h.delivery.undone == ["um ship it on friday"])
        #expect(h.controller.notice == .undone)

        h.controller.handle(.undo)
        await h.controller.settle()
        #expect(h.controller.notice == .nothingToUndo, "an edit is undone once")
    }

    @Test func undoAfterTheWindowDoesNothing() async {
        let h = Harness(transcript: "um ship it on friday")
        h.controller.start()
        await h.hold(milliseconds: 500)
        await h.release()
        h.clock.advance(by: .seconds(31))
        h.controller.undoLastEdit()
        await h.controller.settle()
        #expect(await h.delivery.undone.isEmpty)
        #expect(h.controller.notice == .nothingToUndo)
    }

    @Test func theMenuCanStartAndStopADictation() async {
        let h = Harness()
        h.controller.start()
        h.controller.toggleDictation()
        await h.controller.settle()
        #expect(h.controller.phase == .recording(handsFree: true))
        await h.source.push([Float](repeating: 0.1, count: AudioFormat.samples(forMilliseconds: 400)))
        try? await Task.sleep(for: .milliseconds(20))
        h.controller.toggleDictation()
        await h.controller.settle()
        #expect(await h.delivery.inserted == ["Ship it on friday."])
    }

    @Test func escapeCancelsADictationStartedFromTheMenu() async {
        let h = Harness()
        h.controller.start()
        h.controller.toggleDictation()
        await h.controller.settle()
        h.controller.handle(.escape)
        await h.controller.settle()
        #expect(h.controller.phase == .idle)
        #expect(h.controller.notice == .cancelled)
    }

    @Test func theHotkeyStopsADictationStartedFromTheMenu() async {
        let h = Harness()
        h.controller.start()
        h.controller.toggleDictation()
        await h.controller.settle()
        await h.source.push([Float](repeating: 0.1, count: AudioFormat.samples(forMilliseconds: 400)))
        try? await Task.sleep(for: .milliseconds(20))
        h.controller.handle(.pressed)
        await h.controller.settle()
        h.controller.handle(.released)
        await h.controller.settle()
        #expect(await h.delivery.inserted == ["Ship it on friday."])

        await h.hold(milliseconds: 500)
        await h.release()
        #expect(await h.delivery.inserted.count == 2, "the next press is an ordinary push-to-talk")
    }

    @Test func aRefusedMenuDictationLeavesTheHotkeyWorking() async {
        let ready = ReadinessSwitch(.modelsLoading)
        let h = Harness(readiness: ready)
        h.controller.start()
        h.controller.toggleDictation()
        await h.controller.settle()
        #expect(h.controller.notice == .modelsLoading)
        ready.set(.ready)
        await h.hold(milliseconds: 500)
        await h.release()
        #expect(await h.delivery.inserted == ["Ship it on friday."])
    }

    @Test func undoPressedWithTheHotkeyHeldCancelsThenUndoes() async {
        let h = Harness(transcript: "um ship it on friday")
        h.controller.start()
        await h.hold(milliseconds: 500)
        await h.release()
        await h.hold(milliseconds: 200)
        h.controller.handle(.otherKey)
        h.controller.handle(.undo)
        await h.controller.settle()
        #expect(h.controller.phase == .idle)
        #expect(await h.delivery.undone == ["um ship it on friday"])
    }

    @Test func undoIsIgnoredWhileRecording() async {
        let h = Harness(transcript: "um ship it on friday")
        h.controller.start()
        await h.hold(milliseconds: 500)
        await h.release()
        h.controller.toggleDictation()
        await h.controller.settle()
        h.controller.undoLastEdit()
        await h.controller.settle()
        #expect(await h.delivery.undone.isEmpty)
    }

    @Test func aPressWhileProcessingSaysSoInsteadOfRecordingLate() async {
        let h = Harness()
        await h.transcriber.hold()
        h.controller.start()
        await h.hold(milliseconds: 500)
        h.controller.handle(.released)
        await h.transcriber.waitForCall()
        #expect(h.controller.phase == .processing)

        h.controller.handle(.pressed)
        #expect(h.controller.progressNotice == .stillProcessing, "shown under Transcribing…")
        h.controller.handle(.released)
        await h.transcriber.release()
        await h.controller.settle()
        #expect(await h.delivery.inserted == ["Ship it on friday."])
        #expect(h.controller.phase == .idle)
        #expect(h.controller.notice == .stillProcessing, "and again once the dictation is in")
        #expect(await h.source.starts == 1, "the press during processing never opened the microphone")
    }
}
