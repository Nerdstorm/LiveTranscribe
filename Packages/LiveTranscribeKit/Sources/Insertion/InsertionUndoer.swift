import ApplicationServices
import Foundation
import Shared

/// *Undo AI edit*: swaps the cleaned text just inserted for the uncleaned text, the dictation as
/// it was before cleanup. That is not the literal transcript: snippet expansions and vocabulary
/// spellings, which the user set up, stay applied; only cleanup's edits are taken back.
///
/// In place when possible: an Accessibility insertion whose field is still focused and still holds
/// the text at the recorded range is selected and replaced, which leaves the rest of the field and
/// the app's undo history alone. Otherwise ⌘Z undoes the insertion and the uncleaned text is
/// inserted through the router.
///
/// ⌘Z only ever goes to the app that received the insertion, and never to another field of it or
/// to a field that has visibly changed since: in each case it would undo something the user did.
/// The field is compared whatever the insertion method, pasted text included, whenever
/// Accessibility saw it both at the insertion and now; when either side is unknown (apps that
/// hide their fields from Accessibility), only the app check applies, and an app that reports one
/// element for all its fields passes it whichever field has focus. Whether the field was
/// edited since can be checked only for an Accessibility insertion, which records where the text
/// went: a paste records no range, so typing after it in the same field is not detected.
///
/// The caller enforces the time window (``InsertionRecord/insertedAt``, 30 s by default) and
/// captures `target` when the undo shortcut is pressed.
public struct InsertionUndoer: Sendable {
    private let router: InsertionRouter
    private let keystrokes: any KeystrokeSender
    private let settleDelayMs: Int

    /// - Parameter settleDelayMs: How long the app gets to apply an edit before the next step:
    ///   after ⌘Z before inserting (inserting earlier could land before the undo and be undone
    ///   with it), and before reading the field a second time when an in-place replacement
    ///   still shows the old text (see ``AXTextInserter``).
    public init(router: InsertionRouter, keystrokes: any KeystrokeSender, settleDelayMs: Int) {
        self.router = router
        self.keystrokes = keystrokes
        self.settleDelayMs = max(0, settleDelayMs)
    }

    /// Replaces `record`'s text with `uncleaned` in `target`, the focus when undo was pressed.
    public func undo(_ record: InsertionRecord, replacingWith uncleaned: String, in target: InsertionTarget) async -> UndoResult {
        guard let insertedInto = record.app, let current = target.app, insertedInto == current else {
            Log.insertion.info("""
                Undo refused: \(target.app?.bundleIdentifier ?? "an unknown app", privacy: .public) is in front, \
                not \(record.app?.bundleIdentifier ?? "an unknown app", privacy: .public)
                """)
            return .refusedDifferentApp
        }
        guard !target.isSecure else {
            Log.insertion.info("Undo refused: the focused field is secure")
            return .refusedSecureField
        }
        // Before any strategy: ⌘Z and the insertion that follows it both act on the focused field.
        if let inserted = record.element, let focused = target.element, !inserted.isSameElement(as: focused) {
            Log.insertion.info("""
                Undo refused: focus moved to another field of \(current.bundleIdentifier ?? "the app", privacy: .public) \
                since the \(record.method.rawValue, privacy: .public) insertion
                """)
            return .refusedFocusMoved
        }

        switch await replaceInPlace(record, with: uncleaned, focusIsKnown: target.element != nil) {
        case .done(let result):
            return result
        case .refused:
            return .refusedFieldChanged
        case .notApplicable:
            return await undoWithKeystroke(thenInsert: uncleaned, into: target)
        }
    }

    // MARK: - In place

    private enum InPlaceOutcome {
        /// Finished, one way or the other.
        case done(UndoResult)
        /// The field changed since the insertion; ⌘Z must not be sent either.
        case refused
        /// In place does not apply, and the field is as it was: ⌘Z is safe to try.
        case notApplicable
    }

    /// `focusIsKnown` is whether Accessibility could see the focused field when undo was pressed;
    /// ``undo(_:replacingWith:in:)`` has already checked that it is the recorded one. When it is
    /// unknown, the recorded field may not be the one the user is in, so it is not edited.
    private func replaceInPlace(
        _ record: InsertionRecord,
        with uncleaned: String,
        focusIsKnown: Bool
    ) async -> InPlaceOutcome {
        guard record.method == .accessibility, let range = record.range, let element = record.element, focusIsKnown else {
            return .notApplicable
        }
        guard let value = element.string(kAXValueAttribute) else { return .notApplicable }
        guard Self.value(value, holds: record.text, at: range) else {
            Log.insertion.info("Undo refused: the field was edited since the insertion")
            return .refused
        }
        guard element.setRange(range, for: kAXSelectedTextRangeAttribute),
              element.range(kAXSelectedTextRangeAttribute) == range
        else {
            Log.insertion.info("Undo in place unavailable: the app did not select the inserted text")
            return .notApplicable
        }

        do {
            let replaced = try await AXTextInserter.replaceSelection(
                of: element, with: uncleaned, verificationDelayMs: settleDelayMs
            )
            Log.insertion.info("Undo: replaced the edit in place")
            return .done(.replacedInPlace(range: replaced))
        } catch where error.mayHaveChangedField {
            Log.insertion.error("Undo in place changed the field unexpectedly; the original is on the clipboard")
            guard case .copiedToClipboard = router.copyToClipboard(uncleaned, because: .notAccepted) else {
                return .done(.failed)
            }
            return .done(.copiedToClipboard)
        } catch {
            Log.insertion.info("Undo in place failed (\(error.localizedDescription, privacy: .public)); using ⌘Z")
            return .notApplicable
        }
    }

    /// Whether `value` still holds `text` at `range`, code unit for code unit.
    static func value(_ value: String, holds text: String, at range: NSRange) -> Bool {
        guard range.isWithin(utf16Count: value.utf16.count) else { return false }
        return AXTextInserter.isIdentical((value as NSString).substring(with: range), text)
    }

    // MARK: - ⌘Z

    private func undoWithKeystroke(thenInsert uncleaned: String, into target: InsertionTarget) async -> UndoResult {
        guard keystrokes.sendUndo() else {
            Log.insertion.error("Undo failed: ⌘Z could not be sent")
            return .failed
        }
        // Not cancellable: the edit is being undone, and the uncleaned text must follow it.
        await sleepIgnoringCancellation(milliseconds: settleDelayMs)
        let result = await router.insert(uncleaned, into: target)
        Log.insertion.info("Undo: sent ⌘Z, then inserted the original (\(String(describing: result), privacy: .public))")
        return .undoneAndInserted(result)
    }
}
