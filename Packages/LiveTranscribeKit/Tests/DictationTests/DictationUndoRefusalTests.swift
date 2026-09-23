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

    /// ⌘Z went to the app but the insert after it was refused because focus turned to a password
    /// field: the notice says so, not that the text is on the clipboard, and the entry is spent,
    /// so another press cannot send a second ⌘Z.
    @Test func aRefusedInsertAfterTheUndoKeystrokeIsReportedAndEndsTheEntry() async {
        let h = Harness(transcript: "um ship it on friday")
        h.controller.start()
        await h.hold(milliseconds: 500)
        await h.release()
        await h.delivery.set(undoResult: .undoneAndInserted(.refusedSecureField))

        h.controller.handle(.undo)
        await h.controller.settle()
        #expect(h.controller.notice == .secureField)

        h.controller.handle(.undo)
        await h.controller.settle()
        #expect(h.controller.notice == .nothingToUndo)
        #expect(await h.delivery.undone.count == 1)
    }

    @Test("After ⌘Z, the notice follows what the insert did", arguments: [
        (InsertionResult.inserted(.paste, range: nil), DictationNotice.undone),
        (.nothingToInsert, .undone),
        (.copiedToClipboard(.notAccepted), .undoCopiedToClipboard),
        (.copiedToClipboard(.focusMoved), .undoCopiedToClipboard),
        (.copiedToClipboard(.pasteNotPermitted), .undoCopiedToClipboard),
        (.refusedSecureField, .secureField),
        (.failed, .undoFailed),
    ])
    func noticeAfterTheUndoKeystroke(inserted: InsertionResult, notice: DictationNotice) {
        #expect(DictationController.notice(for: .undoneAndInserted(inserted)) == notice)
        #expect(UndoResult.undoneAndInserted(inserted).sentUndoKeystroke)
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
