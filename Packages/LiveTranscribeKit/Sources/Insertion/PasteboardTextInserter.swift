import Foundation
import Shared

/// Inserts text by pasting it: the clipboard is swapped for the text, ⌘V is posted, and the
/// user's clipboard is put back.
///
/// The paste itself cannot be verified, so success means ⌘V was posted. The target app reads the
/// pasteboard some time after the key event, hence the delay before restoring; restoring earlier
/// would paste the user's own clipboard instead of the dictated text.
///
/// ⌘V goes to whatever has keyboard focus when it is posted, not to the target, and the target
/// was read before speech-to-text and cleanup ran, up to seconds earlier. So the focus is read
/// again just before the pasteboard is written: if it is now secure (the user tabbed into a
/// password field), or another app has it, nothing is pasted and the pasteboard is left alone.
///
/// Pastes through one inserter (and its copies) run one at a time, in call order: an overlapping
/// paste would snapshot the other's text and restore it over the user's clipboard. Build one
/// inserter and share it (the router and the undoer do, through the router).
public struct PasteboardTextInserter: TextInserter {
    private let pasteboard: any PasteboardAccess
    private let keystrokes: any KeystrokeSender
    private let focus: any FocusedTargetProvider
    private let restoreDelayMs: Int
    private let queue = SerialQueue()

    /// - Parameters:
    ///   - focus: Reads the focused field just before ⌘V, to check it is still safe to paste into.
    ///     Read on the paste queue, never on the main actor, whoever the caller is.
    ///   - restoreDelayMs: How long the text stays on the pasteboard after ⌘V, for the
    ///     target app to read it, before the user's clipboard is restored.
    public init(
        pasteboard: any PasteboardAccess,
        keystrokes: any KeystrokeSender,
        focus: any FocusedTargetProvider,
        restoreDelayMs: Int
    ) {
        self.pasteboard = pasteboard
        self.keystrokes = keystrokes
        self.focus = focus
        self.restoreDelayMs = max(0, restoreDelayMs)
    }

    /// Once called, the paste runs to the end even if the caller is cancelled, including any wait
    /// for an earlier paste; cancel before calling.
    ///
    /// - Throws: ``InsertionError/focusBecameSecure`` or ``InsertionError/focusMovedToAnotherApp``
    ///   when the focus changed since `target` was read; the pasteboard is then untouched.
    public func insert(_ text: String, into target: InsertionTarget) async throws(InsertionError) -> NSRange? {
        try await queue.run { await self.paste(text, into: target) }.get()
    }

    private func paste(_ text: String, into target: InsertionTarget) async -> Result<NSRange?, InsertionError> {
        // Read-only, and possibly slow (it makes other apps provide promised data), so taken
        // before the focus check: the check then runs as close to ⌘V as it can.
        let snapshot = pasteboard.snapshot()
        if let refusal = focusRefusal(for: target) {
            return .failure(refusal)
        }
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

    /// Why ⌘V must not be posted now, or `nil` when the focus is still safe to paste into.
    ///
    /// Only the app is compared, not the element: moving to another field of the same app pastes
    /// there, as typing would.
    private func focusRefusal(for target: InsertionTarget) -> InsertionError? {
        let current = focus.currentTarget()
        let intended = target.app?.bundleIdentifier ?? "an unknown app"
        if current.isSecure {
            Log.insertion.info("Nothing pasted into \(intended, privacy: .public): the focused field became secure")
            return .focusBecameSecure
        }
        guard current.app?.processIdentifier == target.app?.processIdentifier else {
            Log.insertion.info("""
                Nothing pasted into \(intended, privacy: .public): focus moved to \
                \(current.app?.bundleIdentifier ?? "an unknown app", privacy: .public)
                """)
            return .focusMovedToAnotherApp
        }
        return nil
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
