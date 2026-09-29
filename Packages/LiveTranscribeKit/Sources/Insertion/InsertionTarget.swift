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
/// Captured once and passed along, so the processing steps (whether the text may break across
/// lines, see ``AppOverrides/allowsLineBreaks(in:)``) and the insertion agree on the same field.
public struct InsertionTarget: Sendable {
    public let app: AppInfo?
    /// The focused element, or `nil` when nothing is focused or it is out of Accessibility's reach.
    public let element: (any AccessibilityElement)?
    /// A password field, or secure event input is on (a password prompt somewhere has the keyboard).
    public let isSecure: Bool

    public init(app: AppInfo?, element: (any AccessibilityElement)?, isSecure: Bool) {
        self.app = app
        self.element = element
        self.isSecure = isSecure
    }

    /// Derives the flags from the element itself.
    ///
    /// Kept apart from ``SystemFocusedTargetProvider`` so the rules are tested with a fake element.
    /// - Parameter secureEventInputEnabled: `IsSecureEventInputEnabled()`: some app (a password
    ///   prompt, a terminal's secure keyboard entry) has asked that keystrokes not be observable.
    public init(app: AppInfo?, element: (any AccessibilityElement)?, secureEventInputEnabled: Bool) {
        let isSecureField = element?.subrole == kAXSecureTextFieldSubrole
        self.init(app: app, element: element, isSecure: secureEventInputEnabled || isSecureField)
    }
}

/// Reads the field that currently has keyboard focus.
///
/// Read when dictation starts and finishes, and again by ``PasteboardTextInserter`` just before
/// ⌘V. A protocol so the dictation flow and the paste can be tested without Accessibility
/// permission.
public protocol FocusedTargetProvider: Sendable {
    func currentTarget() -> InsertionTarget
}
