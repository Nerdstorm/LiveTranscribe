import ApplicationServices
import Foundation

/// The app that would receive dictated text.
///
/// The process identifier tells two launches of the same app apart, which matters for undo: an
/// element of a relaunched app is a different element.
public struct AppInfo: Sendable, Equatable, Hashable {
    /// `nil` for processes without a bundle (rare: command-line tools with a window).
    public let bundleIdentifier: String?
    /// The localised name, for the HUD ("Copied: Terminal doesn't accept typed text").
    public let name: String
    public let processIdentifier: pid_t

    public init(bundleIdentifier: String?, name: String, processIdentifier: pid_t) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.processIdentifier = processIdentifier
    }
}

/// Where dictated text would go, captured when dictation finishes.
///
/// Captured once and passed along, so the processing steps (list formatting needs
/// ``isMultiline``) and the insertion agree on the same field.
public struct InsertionTarget: Sendable {
    public let app: AppInfo?
    /// The focused element, or `nil` when nothing is focused or it is out of Accessibility's reach.
    public let element: (any AccessibilityElement)?
    /// A password field, or secure event input is on (a password prompt somewhere has the keyboard).
    public let isSecure: Bool
    /// The field takes several lines (`AXTextArea`), so spoken lists may become numbered lines.
    public let isMultiline: Bool
    /// Screen rectangle of the caret or selection, for placing the HUD near it; `nil` if unknown.
    ///
    /// In Accessibility (Quartz) global coordinates: the origin is the top-left corner of the
    /// primary display and y grows downwards. AppKit window frames use a bottom-left origin, so
    /// flip y against the primary screen's height before positioning a window with it.
    public let caretRect: CGRect?

    public init(
        app: AppInfo?,
        element: (any AccessibilityElement)?,
        isSecure: Bool,
        isMultiline: Bool,
        caretRect: CGRect?
    ) {
        self.app = app
        self.element = element
        self.isSecure = isSecure
        self.isMultiline = isMultiline
        self.caretRect = caretRect
    }

    /// Derives the flags and caret from the element itself.
    ///
    /// Kept apart from ``SystemFocusedTargetProvider`` so the rules are tested with a fake element.
    /// - Parameter secureEventInputEnabled: `IsSecureEventInputEnabled()`: some app (a password
    ///   prompt, a terminal's secure keyboard entry) has asked that keystrokes not be observable.
    public init(app: AppInfo?, element: (any AccessibilityElement)?, secureEventInputEnabled: Bool) {
        let isSecureField = element?.subrole == kAXSecureTextFieldSubrole
        let isSecure = secureEventInputEnabled || isSecureField
        // No caret lookup for a secure field: nothing will be inserted there, and it saves a
        // round trip to a possibly slow app.
        let caretRect = isSecure ? nil : element.flatMap(Self.caretRect(of:))
        self.init(
            app: app,
            element: element,
            isSecure: isSecure,
            isMultiline: element?.role == kAXTextAreaRole,
            caretRect: caretRect
        )
    }

    /// The bounds of the selection, ignoring the empty or null rectangles some apps return
    /// instead of an error.
    private static func caretRect(of element: any AccessibilityElement) -> CGRect? {
        guard let selection = element.range(kAXSelectedTextRangeAttribute),
              let rect = element.bounds(for: selection),
              !rect.isNull, rect != .zero
        else { return nil }
        return rect
    }
}

/// Reads the field that currently has keyboard focus.
///
/// A protocol so the dictation flow can be tested without Accessibility permission.
public protocol FocusedTargetProvider: Sendable {
    func currentTarget() -> InsertionTarget
}
