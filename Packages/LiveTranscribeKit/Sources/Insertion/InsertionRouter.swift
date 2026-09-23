import Foundation
import Shared

/// Puts dictated text into the focused field of any app: the one insertion entry point the app calls.
///
/// Order of attempts:
/// 1. A secure target (password field, or secure event input on) gets nothing: not typed, not
///    copied. Checked first, so no method ever runs against it.
/// 2. Accessibility, then paste. An app whose override is ``InsertionMethod/paste``, or a target
///    without a focused element, gets paste only.
/// 3. If every method fails, the text is left on the clipboard for the user to paste.
///
/// Accessibility writes to the target's own element, wherever the focus is now. Paste goes to the
/// current focus, so the paste inserter checks it again just before ⌘V: a field that has become
/// secure is refused as in step 1 (``InsertionError/focusBecameSecure``), and focus in another
/// app leaves the text on the clipboard as in step 3 (``InsertionError/focusMovedToAnotherApp``).
///
/// A failure that may have changed the field (``InsertionError/mayHaveChangedField``) skips the
/// remaining methods and goes straight to the clipboard, so the text is never typed twice.
///
/// Immutable: when the user edits the overrides, build a new router.
public struct InsertionRouter: Sendable {
    private let accessibility: any TextInserter
    private let paste: any TextInserter
    private let pasteboard: any PasteboardAccess
    private let overrides: InserterOverrides

    /// - Parameter overrides: The effective overrides, normally
    ///   `InserterOverrides.bundled.merged(with: userOverrides)`.
    public init(
        accessibility: any TextInserter,
        paste: any TextInserter,
        pasteboard: any PasteboardAccess,
        overrides: InserterOverrides
    ) {
        self.accessibility = accessibility
        self.paste = paste
        self.pasteboard = pasteboard
        self.overrides = overrides
    }

    /// Inserts `text` at the target's cursor, replacing its selection.
    ///
    /// Empty text returns ``InsertionResult/nothingToInsert`` without touching the target or the
    /// clipboard, whatever the target.
    public func insert(_ text: String, into target: InsertionTarget) async -> InsertionResult {
        guard !text.isEmpty else { return .nothingToInsert }
        let app = target.app?.bundleIdentifier ?? "an unknown app"
        guard !target.isSecure else {
            Log.insertion.info("Nothing inserted into \(app, privacy: .public): the focused field is secure")
            return .refusedSecureField
        }

        for method in methods(for: target) {
            do {
                let range = try await inserter(for: method).insert(text, into: target)
                Log.insertion.info("Inserted via \(method.rawValue, privacy: .public) into \(app, privacy: .public)")
                return .inserted(method, range: range)
            } catch {
                Log.insertion.info("""
                    \(method.rawValue, privacy: .public) insertion into \(app, privacy: .public) \
                    failed: \(error.localizedDescription, privacy: .public)
                    """)
                if error == .focusBecameSecure {
                    // Found only just before ⌘V: as for a secure target, nothing is copied either.
                    return .refusedSecureField
                }
                if error.mayHaveChangedField {
                    Log.insertion.error("The field in \(app, privacy: .public) may hold part of the text; not retrying")
                    break
                }
            }
        }
        return copyToClipboard(text)
    }

    /// The methods ``insert(_:into:)`` tries for `target`, in order. Empty for a secure target.
    public func methods(for target: InsertionTarget) -> [InsertionMethod] {
        guard !target.isSecure else { return [] }
        guard target.element != nil else { return [.paste] }
        switch overrides.method(for: target.app?.bundleIdentifier) {
        case .paste: return [.paste]
        case .accessibility, nil: return [.accessibility, .paste]
        }
    }

    /// Leaves `text` on the clipboard as an ordinary copy, for when it could not be inserted.
    public func copyToClipboard(_ text: String) -> InsertionResult {
        guard pasteboard.writeString(text) else {
            Log.insertion.error("Nothing inserted and the clipboard could not be written")
            return .failed
        }
        Log.insertion.info("Text left on the clipboard for the user to paste")
        return .copiedToClipboard
    }

    private func inserter(for method: InsertionMethod) -> any TextInserter {
        switch method {
        case .accessibility: accessibility
        case .paste: paste
        }
    }
}
