import Foundation

/// What was inserted, where and how: everything *Undo AI edit* needs to find the text again.
public struct InsertionRecord: Sendable {
    /// The cleaned text that was inserted.
    public let text: String
    public let method: InsertionMethod
    /// The UTF-16 range the text occupied right after insertion; `nil` for paste.
    public let range: NSRange?
    public let app: AppInfo?
    /// The field it went into, when Accessibility could see it, for either method: undo is
    /// refused once another field has focus.
    public let element: (any AccessibilityElement)?
    /// For the caller's undo window (30 s by default): the undoer does not check it.
    public let insertedAt: ContinuousClock.Instant

    public init(
        text: String,
        method: InsertionMethod,
        range: NSRange?,
        app: AppInfo?,
        element: (any AccessibilityElement)?,
        insertedAt: ContinuousClock.Instant
    ) {
        self.text = text
        self.method = method
        self.range = range
        self.app = app
        self.element = element
        self.insertedAt = insertedAt
    }

    /// The record of a routed insertion, or `nil` if the result did not put the text in the field
    /// (copied, refused, empty, failed), since there is nothing to undo then.
    public init?(text: String, result: InsertionResult, target: InsertionTarget, insertedAt: ContinuousClock.Instant) {
        guard case .inserted(let method, let range) = result else { return nil }
        self.init(
            text: text, method: method, range: range, app: target.app, element: target.element, insertedAt: insertedAt
        )
    }
}

/// What ``InsertionUndoer/undo(_:replacingWith:in:)`` did, for the HUD.
public enum UndoResult: Sendable, Equatable {
    /// The inserted text was selected and replaced with the uncleaned text through Accessibility;
    /// `range` is where the uncleaned text now sits.
    case replacedInPlace(range: NSRange)
    /// ⌘Z was sent, then the uncleaned text went through the router with this result.
    case undoneAndInserted(InsertionResult)
    /// Replacing in place changed the field unexpectedly, so nothing more was tried (⌘Z could
    /// undo the wrong thing); the uncleaned text is on the clipboard.
    case copiedToClipboard
    /// Another app (or an unknown one) is in front; ⌘Z there would undo something unrelated.
    case refusedDifferentApp
    /// Focus moved to another field of the same app, so ⌘Z would undo something in that field.
    /// Nothing changed: undo works again once the dictated field has focus.
    case refusedFocusMoved
    /// The field was edited after the insertion, so ⌘Z would undo the user's own change instead
    /// of the insertion.
    case refusedFieldChanged
    /// The focused field is now secure; nothing is sent to it.
    case refusedSecureField
    /// ⌘Z could not be posted, or the clipboard could not be written. Nothing changed.
    case failed

    /// Whether the uncleaned text has replaced the edit in the field.
    public var succeeded: Bool {
        switch self {
        case .replacedInPlace:
            true
        case .undoneAndInserted(let result):
            result.isInserted || result == .nothingToInsert
        case .copiedToClipboard, .refusedDifferentApp, .refusedFocusMoved, .refusedFieldChanged, .refusedSecureField,
             .failed:
            false
        }
    }

    /// Whether ⌘Z was sent to the app, so the cleaned text may already be gone whatever the
    /// insert that followed did.
    public var sentUndoKeystroke: Bool {
        if case .undoneAndInserted = self { true } else { false }
    }
}
