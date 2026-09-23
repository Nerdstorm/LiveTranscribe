@testable import Dictation
import Foundation
import Testing

/// The HUD is placed at ``DictationController/caretRect``: it must never show the last
/// dictation's caret, which may be in another app or on another display.
@MainActor
@Suite("DictationController caret")
struct DictationCaretTests {
    private static let first = CGRect(x: 100, y: 200, width: 2, height: 16)
    private static let second = CGRect(x: 900, y: 40, width: 2, height: 18)

    /// A harness that has dictated once into a field with its caret at ``first``.
    private func harnessAfterOneDictation(readiness: ReadinessSwitch = ReadinessSwitch(.ready)) async -> Harness {
        let h = Harness(readiness: readiness)
        h.focus.set(FakeFocus.field(caret: Self.first))
        h.controller.start()
        await h.hold(milliseconds: 500)
        await h.release()
        #expect(h.controller.caretRect == Self.first)
        return h
    }

    @Test func aNewRecordingDoesNotStartAtTheLastCaret() async {
        let h = await harnessAfterOneDictation()
        h.focus.set(FakeFocus.field(caret: Self.second))
        h.focus.holdLookups()
        defer { h.focus.releaseLookups() }

        h.controller.handle(.pressed)
        #expect(await eventually { h.controller.phase == .recording(handsFree: false) })
        #expect(h.controller.caretRect == nil, "the HUD shows by the pointer until the field is read")

        h.focus.releaseLookups()
        await h.controller.settle()
        #expect(h.controller.caretRect == Self.second)
        h.controller.cancel()
        await h.controller.settle()
    }

    @Test("A refused attempt is not placed at the last caret", arguments: [
        DictationReadiness.modelsLoading, .liveTranscriptRunning,
    ])
    func aRefusalClearsTheCaret(readiness: DictationReadiness) async {
        let ready = ReadinessSwitch(.ready)
        let h = await harnessAfterOneDictation(readiness: ready)
        ready.set(readiness)
        await h.hold(milliseconds: 500)
        #expect(h.controller.notice != nil)
        #expect(h.controller.caretRect == nil)
    }

    @Test func aPasswordFieldClearsTheCaret() async {
        let h = await harnessAfterOneDictation()
        h.focus.set(FakeFocus.field(value: "", secure: true))
        await h.hold(milliseconds: 500)
        #expect(h.controller.notice == .secureField)
        #expect(h.controller.caretRect == nil)
    }

    // MARK: - Notices outside a dictation

    @Test func anUndoIsPlacedAtTheFieldItUndoesIn() async {
        let h = await harnessAfterOneDictation()
        h.focus.set(FakeFocus.field(caret: Self.second))
        h.controller.undoLastEdit()
        await h.controller.settle()
        #expect(h.controller.notice == .undone)
        #expect(h.controller.caretRect == Self.second)
    }

    @Test func nothingToUndoIsNotPlacedAtTheLastCaret() async {
        let h = await harnessAfterOneDictation()
        h.clock.advance(by: .seconds(31))
        h.controller.undoLastEdit()
        await h.controller.settle()
        #expect(h.controller.notice == .nothingToUndo)
        #expect(h.controller.caretRect == nil, "the field it names may be long gone")
    }

    @Test func aMicrophoneNoticeBetweenDictationsIsNotPlacedAtTheLastCaret() async {
        let h = await harnessAfterOneDictation()
        h.controller.showMicrophoneNotice("Using AirPods")
        #expect(h.controller.caretRect == nil)
    }

    @Test func aMicrophoneNoticeWhileRecordingStaysAtTheCaret() async {
        let h = await harnessAfterOneDictation()
        await h.hold(milliseconds: 500)
        #expect(h.controller.phase == .recording(handsFree: false))
        h.controller.showMicrophoneNotice("Using AirPods")
        #expect(h.controller.caretRect == Self.first, "it concerns this dictation")
        h.controller.cancel()
        await h.controller.settle()
    }
}
