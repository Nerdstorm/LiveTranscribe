import Foundation

/// A way of putting text into another app's focused field.
///
/// Stored by raw value in the per-app overrides file, so the raw values must not change.
public enum InsertionMethod: String, Codable, Sendable, CaseIterable {
    /// Replace the field's selection through the Accessibility API, then verify by reading the
    /// field back. Precise and leaves the clipboard alone, but many apps (terminals, Electron and
    /// Chromium) ignore the write or report it wrongly.
    case accessibility
    /// Put the text on the pasteboard and post ⌘V. Works almost everywhere, but cannot be
    /// verified and briefly replaces the clipboard.
    case paste

    /// Name for the per-app override picker in Settings.
    public var displayName: String {
        switch self {
        case .accessibility: "Accessibility"
        case .paste: "Paste"
        }
    }
}

/// What ``InsertionRouter/insert(_:into:)`` did with the text, for the HUD and the undo buffer.
public enum InsertionResult: Sendable, Equatable {
    /// The text went into the field. `range` is the UTF-16 range it now occupies when the method
    /// can know it (Accessibility); `nil` for paste, which cannot be verified.
    case inserted(InsertionMethod, range: NSRange?)
    /// The text was left on the clipboard for the user to paste themselves, for `reason`.
    case copiedToClipboard(ClipboardReason)
    /// The focused field is a password field (or secure event input is on), either when the
    /// target was read or when focus was checked again just before pasting: nothing was typed
    /// and nothing was copied, so dictated text never lands somewhere hidden.
    case refusedSecureField
    /// The text was empty, so nothing was attempted. Callers normally skip insertion before this.
    case nothingToInsert
    /// No method worked and the clipboard could not be written either. The text is only in
    /// history; the HUD should say that nothing was inserted.
    case failed

    /// Whether the text is now in the field.
    public var isInserted: Bool {
        if case .inserted = self { return true }
        return false
    }
}

/// Why ``InsertionResult/copiedToClipboard(_:)`` left the text on the clipboard: the HUD tells
/// the user what to do about it, which differs by cause.
public enum ClipboardReason: Sendable, Equatable {
    /// The app took neither an Accessibility insertion nor a paste, or the text may be partly in
    /// the field already.
    case notAccepted
    /// Another app had keyboard focus by the time the text was ready, so ⌘V would have gone there.
    case focusMoved
    /// macOS does not let Live Transcribe post keystrokes, so no paste was tried.
    case pasteNotPermitted
}

/// Why one insertion method did not put the text in the field.
public enum InsertionError: LocalizedError, Equatable, Sendable {
    /// No element has keyboard focus (or it is not reachable through Accessibility).
    case noFocusedElement
    /// The field's value can't be read, so an Accessibility write could not be verified.
    case valueUnreadable
    /// The field's selection can't be read, or lies outside its value.
    case selectionUnreadable
    /// The app refused the Accessibility write and the field is unchanged.
    case writeRejected
    /// The app reported that it accepted the write, but the field is unchanged.
    case writeIgnored
    /// The field changed, but not into the expected text. Part of the text may be in it.
    case verificationFailed
    /// The text could not be put on the pasteboard, so there was nothing to paste.
    case pasteboardWriteFailed
    /// ⌘V could not be created or posted.
    case keystrokeFailed
    /// macOS does not let this process post keystrokes, so ⌘V was not tried and the pasteboard
    /// was not touched. The permission comes with Accessibility, but a running app can be trusted
    /// for Accessibility and still be refused here until it is reopened.
    case pasteNotPermitted
    /// Just before ⌘V, the focused field turned out to be secure (focus moved to a password
    /// field, or secure event input came on, after the target was read). Nothing was pasted and
    /// the pasteboard was not touched.
    case focusBecameSecure
    /// Just before ⌘V, another app had keyboard focus: ⌘V would have gone there instead. Nothing
    /// was pasted and the pasteboard was not touched.
    case focusMovedToAnotherApp

    public var errorDescription: String? {
        switch self {
        case .noFocusedElement:
            "No text field has keyboard focus."
        case .valueUnreadable:
            "The focused field's text can't be read, so typing into it can't be checked."
        case .selectionUnreadable:
            "The cursor position in the focused field can't be read."
        case .writeRejected:
            "The app refused the text."
        case .writeIgnored:
            "The app accepted the text but did not show it."
        case .verificationFailed:
            "The field changed, but not into the dictated text."
        case .pasteboardWriteFailed:
            "The text could not be put on the clipboard for pasting."
        case .keystrokeFailed:
            "The paste shortcut could not be sent."
        case .pasteNotPermitted:
            "macOS doesn't let Live Transcribe send the paste shortcut."
        case .focusBecameSecure:
            "Focus moved to a password field before the text could be pasted."
        case .focusMovedToAnotherApp:
            "Focus moved to another app before the text could be pasted."
        }
    }

    /// Whether the field may already hold some or all of the text.
    ///
    /// When it may, trying another method could type the text twice, so the router stops and
    /// leaves the text on the clipboard instead. Every other failure leaves the field as it was.
    public var mayHaveChangedField: Bool {
        self == .verificationFailed
    }

    /// What to tell the user when this was the last failure before the text went to the clipboard.
    public var clipboardReason: ClipboardReason {
        switch self {
        case .pasteNotPermitted: .pasteNotPermitted
        case .focusMovedToAnotherApp: .focusMoved
        default: .notAccepted
        }
    }
}

/// One way of inserting text into the focused field of another app.
///
/// Implementations must not throw after changing the field unless the error reports
/// ``InsertionError/mayHaveChangedField``, because the router then tries the next method.
public protocol TextInserter: Sendable {
    /// Inserts `text` at the target's cursor, replacing its selection.
    ///
    /// - Returns: The UTF-16 range the text now occupies, when the method can know it; `nil`
    ///   when the insertion cannot be verified (paste).
    func insert(_ text: String, into target: InsertionTarget) async throws(InsertionError) -> NSRange?
}
