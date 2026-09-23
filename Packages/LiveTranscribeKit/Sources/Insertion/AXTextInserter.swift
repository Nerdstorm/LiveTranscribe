import ApplicationServices
import Foundation
import Shared

/// Inserts text by replacing the focused field's selection through the Accessibility API.
///
/// Only used when the field's value and selection can be read, because the write is verified by
/// reading the value back: it succeeds only when the value is exactly the old value with the
/// selection replaced by the text. Many apps accept the write and do nothing, or report failure
/// after applying it, so the return code of the write alone is never trusted.
///
/// Duplicate text: a failure is only safe to follow with paste if the field is unchanged.
/// - When the value changed but not into the expected text (the app transformed or truncated it,
///   or edited the field at the same moment), the error is ``InsertionError/verificationFailed``,
///   which reports ``InsertionError/mayHaveChangedField``. The router then does not paste, and
///   leaves the text on the clipboard instead. Nothing is rolled back, since a rollback could
///   itself go wrong in an app that already misbehaved.
/// - Some apps (Chromium and Electron ones, whose Accessibility writes travel to another process)
///   apply the write a moment after reporting the old value. So an unchanged field is read once
///   more after the verification delay before the write is judged ignored.
/// - The remaining risk is an app that applies the write later than that second read: it is
///   judged unchanged and pasted into, giving the text twice. The bundled overrides send the
///   known offenders straight to paste.
public struct AXTextInserter: TextInserter {
    private let verificationDelayMs: Int

    /// - Parameter verificationDelayMs: How long to wait before reading the field a second time
    ///   when it still holds the old value right after the write. Costs nothing when the first
    ///   read already shows the text; `0` reads again at once.
    public init(verificationDelayMs: Int) {
        self.verificationDelayMs = max(0, verificationDelayMs)
    }

    public func insert(_ text: String, into target: InsertionTarget) async throws(InsertionError) -> NSRange? {
        guard let element = target.element else { throw .noFocusedElement }
        return try await Self.replaceSelection(of: element, with: text, verificationDelayMs: verificationDelayMs)
    }

    /// Replaces the element's current selection with `text` and verifies the result.
    ///
    /// Shared with ``InsertionUndoer``, which selects the range to replace first.
    /// - Returns: The UTF-16 range `text` now occupies.
    static func replaceSelection(
        of element: any AccessibilityElement,
        with text: String,
        verificationDelayMs: Int
    ) async throws(InsertionError) -> NSRange {
        guard let before = element.string(kAXValueAttribute) else { throw .valueUnreadable }
        guard let selection = element.range(kAXSelectedTextRangeAttribute),
              selection.isWithin(utf16Count: before.utf16.count)
        else { throw .selectionUnreadable }

        let expected = (before as NSString).replacingCharacters(in: selection, with: text)
        let accepted = element.setString(text, for: kAXSelectedTextAttribute)

        var readBack = ReadBack(of: element, before: before, expected: expected)
        if case .unchanged = readBack {
            // Not cancellable: the write is out, and the app may still apply it.
            await sleepIgnoringCancellation(milliseconds: verificationDelayMs)
            readBack = ReadBack(of: element, before: before, expected: expected)
            if case .applied = readBack {
                Log.insertion.info("AX insert: the app applied the text only after reporting the old value")
            }
        }

        switch readBack {
        case .applied:
            if !accepted {
                Log.insertion.info("AX insert: the app reported failure but applied the text")
            }
            return NSRange(location: selection.location, length: text.utf16.count)
        case .unchanged:
            throw accepted ? .writeIgnored : .writeRejected
        case .unreadable:
            // Readable a moment ago; now nothing is known about what the write did.
            Log.insertion.error("AX insert unverifiable: the value became unreadable after the write")
            throw .verificationFailed
        case .changedUnexpectedly(let afterCount):
            Log.insertion.error("""
                AX insert changed the field unexpectedly: \(before.utf16.count, privacy: .public) → \
                \(afterCount, privacy: .public) UTF-16 units, expected \(expected.utf16.count, privacy: .public)
                """)
            throw .verificationFailed
        }
    }

    /// Code-unit equality. `==` on `String` treats canonically equivalent text as equal, but an
    /// app that renormalised the text would leave the returned range pointing at the wrong units.
    static func isIdentical(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf16.elementsEqual(rhs.utf16)
    }

    /// What reading the value back after a write showed.
    private enum ReadBack {
        /// Exactly the old value with the selection replaced by the text.
        case applied
        /// Exactly the old value.
        case unchanged
        /// The value can no longer be read.
        case unreadable
        /// Something else; carries its UTF-16 length for the log (never the text itself).
        case changedUnexpectedly(utf16Count: Int)

        init(of element: any AccessibilityElement, before: String, expected: String) {
            guard let after = element.string(kAXValueAttribute) else {
                self = .unreadable
                return
            }
            // Expected first: replacing a selection with identical text leaves the value as it was.
            if AXTextInserter.isIdentical(after, expected) {
                self = .applied
            } else if AXTextInserter.isIdentical(after, before) {
                self = .unchanged
            } else {
                self = .changedUnexpectedly(utf16Count: after.utf16.count)
            }
        }
    }
}

extension NSRange {
    /// Whether the range lies inside a string of `count` UTF-16 units.
    ///
    /// Ranges come from other apps and can hold anything, including `NSNotFound` or a length near
    /// `Int.max`. `NSMaxRange` would overflow (and trap) on those, so the end is never computed.
    func isWithin(utf16Count count: Int) -> Bool {
        location >= 0 && length >= 0 && location <= count && length <= count - location
    }
}
