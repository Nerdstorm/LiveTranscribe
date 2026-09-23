@testable import Dictation
import Foundation
import Insertion
import Testing

@MainActor
@Suite("DictationController undo refusals")
struct DictationUndoRefusalTests {
    /// Focus moved to another field of the app: the HUD says how to undo, and the edit stays
    /// undoable, so clicking back into the field and pressing the shortcut again works.
    @Test func focusMovedSaysWhereToUndoAndKeepsTheEdit() async {
        let h = Harness(transcript: "um ship it on friday")
        h.controller.start()
        await h.hold(milliseconds: 500)
        await h.release()
        await h.delivery.set(undoResult: .refusedFocusMoved)

        h.controller.handle(.undo)
        await h.controller.settle()
        #expect(h.controller.notice == .undoRefused("Click back into the field you dictated into to undo"))
        #expect(h.controller.notice?.isProblem == true)

        await h.delivery.set(undoResult: .replacedInPlace(range: NSRange(location: 0, length: 20)))
        h.controller.handle(.undo)
        await h.controller.settle()
        #expect(h.controller.notice == .undone)
        #expect(await h.delivery.undone == ["um ship it on friday", "um ship it on friday"])
    }

    @Test("Each refusal has its own message", arguments: [
        (UndoResult.refusedDifferentApp, "Switch back to the app you dictated into to undo"),
        (.refusedFocusMoved, "Click back into the field you dictated into to undo"),
        (.refusedFieldChanged, "The text was edited since, so it wasn't undone"),
    ])
    func refusalMessages(result: UndoResult, message: String) {
        #expect(DictationController.notice(for: result) == .undoRefused(message))
    }
}
