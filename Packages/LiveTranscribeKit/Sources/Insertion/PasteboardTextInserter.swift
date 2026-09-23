import Foundation
import Shared

/// Inserts text by pasting it: the clipboard is swapped for the text, ⌘V is posted, and the
/// user's clipboard is put back.
///
/// The paste itself cannot be verified, so success means ⌘V was posted. The target app reads the
/// pasteboard some time after the key event, hence the delay before restoring; restoring earlier
/// would paste the user's own clipboard instead of the dictated text.
///
/// Pastes through one inserter (and its copies) run one at a time, in call order: an overlapping
/// paste would snapshot the other's text and restore it over the user's clipboard. Build one
/// inserter and share it (the router and the undoer do, through the router).
public struct PasteboardTextInserter: TextInserter {
    private let pasteboard: any PasteboardAccess
    private let keystrokes: any KeystrokeSender
    private let restoreDelayMs: Int
    private let queue = SerialQueue()

    /// - Parameter restoreDelayMs: How long the text stays on the pasteboard after ⌘V, for the
    ///   target app to read it, before the user's clipboard is restored.
    public init(pasteboard: any PasteboardAccess, keystrokes: any KeystrokeSender, restoreDelayMs: Int) {
        self.pasteboard = pasteboard
        self.keystrokes = keystrokes
        self.restoreDelayMs = max(0, restoreDelayMs)
    }

    /// Once called, the paste runs to the end even if the caller is cancelled, including any wait
    /// for an earlier paste; cancel before calling.
    public func insert(_ text: String, into target: InsertionTarget) async throws(InsertionError) -> NSRange? {
        try await queue.run { await self.paste(text, into: target) }.get()
    }

    private func paste(_ text: String, into target: InsertionTarget) async -> Result<NSRange?, InsertionError> {
        let snapshot = pasteboard.snapshot()
        guard let ourChangeCount = pasteboard.writeTransient(text) else {
            // The write may have cleared the pasteboard before failing.
            restore(snapshot, ifStill: nil)
            return .failure(.pasteboardWriteFailed)
        }

        let posted = keystrokes.sendPaste()
        if posted {
            // Not cancellable: once ⌘V is out, restoring early would paste the wrong text.
            await sleepIgnoringCancellation(milliseconds: restoreDelayMs)
        }
        restore(snapshot, ifStill: ourChangeCount)

        guard posted else { return .failure(.keystrokeFailed) }
        Log.insertion.info("""
            Pasted \(text.utf16.count, privacy: .public) UTF-16 units into \
            \(target.app?.bundleIdentifier ?? "an unknown app", privacy: .public)
            """)
        return .success(nil)
    }

    /// Puts the user's clipboard back, unless it changed after our write (the user copied
    /// something meanwhile, and that is now what they expect to paste).
    /// - Parameter changeCount: The change count right after our write; `nil` restores regardless.
    private func restore(_ snapshot: PasteboardSnapshot, ifStill changeCount: Int?) {
        if let changeCount, pasteboard.changeCount != changeCount {
            Log.insertion.info("Clipboard not restored: it changed while pasting")
            return
        }
        pasteboard.restore(snapshot)
    }
}
