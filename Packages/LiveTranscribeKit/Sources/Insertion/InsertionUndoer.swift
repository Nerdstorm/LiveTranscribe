import ApplicationServices
import Foundation
import Shared

/// *Undo AI edit*: swaps the cleaned text just inserted for the raw transcript.
///
/// In place when possible: an Accessibility insertion whose field is still focused and still holds
/// the text at the recorded range is selected and replaced, which leaves the rest of the field and
/// the app's undo history alone. Otherwise ⌘Z undoes the insertion and the raw transcript is
/// inserted through the router.
///
/// ⌘Z only ever goes to the app that received the insertion, and never to a field that has
/// visibly changed since: in either case it would undo something the user did.
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

    public func undo(_ record: InsertionRecord, replacingWith raw: String, in target: InsertionTarget) async -> UndoResult {
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

        switch await replaceInPlace(record, with: raw, focused: target.element) {
        case .done(let result):
            return result
        case .refused:
            return .refusedFieldChanged
        case .notApplicable:
            return await undoWithKeystroke(thenInsert: raw, into: target)
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

    private func replaceInPlace(
        _ record: InsertionRecord,
        with raw: String,
        focused: (any AccessibilityElement)?
    ) async -> InPlaceOutcome {
        guard record.method == .accessibility, let range = record.range, let element = record.element else {
            return .notApplicable
        }
        guard let focused else { return .notApplicable }
        guard element.isSameElement(as: focused) else {
            Log.insertion.info("Undo refused: focus moved to another field since the insertion")
            return .refused
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
                of: element, with: raw, verificationDelayMs: settleDelayMs
            )
            Log.insertion.info("Undo: replaced the edit in place")
            return .done(.replacedInPlace(range: replaced))
        } catch where error.mayHaveChangedField {
            Log.insertion.error("Undo in place changed the field unexpectedly; the original is on the clipboard")
            return .done(router.copyToClipboard(raw) == .copiedToClipboard ? .copiedToClipboard : .failed)
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

    private func undoWithKeystroke(thenInsert raw: String, into target: InsertionTarget) async -> UndoResult {
        guard keystrokes.sendUndo() else {
            Log.insertion.error("Undo failed: ⌘Z could not be sent")
            return .failed
        }
        // Not cancellable: the edit is being undone, and the raw transcript must follow it.
        await sleepIgnoringCancellation(milliseconds: settleDelayMs)
        let result = await router.insert(raw, into: target)
        Log.insertion.info("Undo: sent ⌘Z, then inserted the original (\(String(describing: result), privacy: .public))")
        return .undoneAndInserted(result)
    }
}
