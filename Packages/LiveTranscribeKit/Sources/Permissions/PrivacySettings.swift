import AppKit
import Capture
import Foundation
import Shared

/// A permission dictation needs, with what to tell the user about it.
public enum RequiredPermission: String, CaseIterable, Sendable, Identifiable {
    case microphone
    case accessibility

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .microphone: "Microphone"
        case .accessibility: "Accessibility"
        }
    }

    /// Why the app needs it, in one sentence.
    public var reason: String {
        switch self {
        case .microphone:
            "To hear you. Audio is transcribed on this Mac and never leaves it."
        case .accessibility:
            "To notice the dictation key in any app and type the text where your cursor is."
        }
    }

    /// The System Settings pane where the user grants it.
    public var settingsURL: URL? {
        switch self {
        case .microphone: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        case .accessibility: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        }
    }
}

/// The permissions dictation needs, as last checked.
public struct PermissionSnapshot: Sendable, Equatable {
    public var microphone: MicrophonePermissionStatus
    public var accessibility: Bool

    public init(microphone: MicrophonePermissionStatus, accessibility: Bool) {
        self.microphone = microphone
        self.accessibility = accessibility
    }

    /// What is still missing, in the order onboarding asks for it.
    public var missing: [RequiredPermission] {
        var missing: [RequiredPermission] = []
        if microphone != .granted { missing.append(.microphone) }
        if !accessibility { missing.append(.accessibility) }
        return missing
    }

    public var allGranted: Bool { missing.isEmpty }
}

/// Opens System Settings where setup sends the user: a permission's list under Privacy &
/// Security, and Keyboard, where *Press 🌐 key to* is (the fn key clashes with dictation unless
/// it is set to Do Nothing).
///
/// Every `open` reports whether System Settings opened, so the caller can say what to do by hand.
@MainActor
public enum PrivacySettings {
    /// System Settings › Keyboard.
    public nonisolated static let keyboardSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")

    /// What to show when ``openKeyboardSettings()`` fails.
    public nonisolated static let keyboardSettingsFailureMessage =
        "Couldn't open System Settings. Open it from the Apple menu, then choose Keyboard."

    /// Opens the list where the user grants `permission`.
    ///
    /// - Returns: Whether System Settings opened. A failure is logged.
    @discardableResult
    public static func open(_ permission: RequiredPermission) -> Bool {
        open(permission.settingsURL, pane: permission.rawValue) { NSWorkspace.shared.open($0) }
    }

    /// Opens System Settings › Keyboard.
    ///
    /// - Returns: Whether System Settings opened. A failure is logged; the caller shows
    ///   ``keyboardSettingsFailureMessage``.
    @discardableResult
    public static func openKeyboardSettings() -> Bool {
        open(keyboardSettingsURL, pane: "keyboard") { NSWorkspace.shared.open($0) }
    }

    /// Opens `url` with `openURL`, logging why it didn't work.
    ///
    /// - Parameters:
    ///   - url: The pane's link; `nil` when it could not be built.
    ///   - pane: Names the pane in the log.
    ///   - openURL: Opens a link and reports whether it worked; tests pass a fake.
    static func open(_ url: URL?, pane: String, with openURL: (URL) -> Bool) -> Bool {
        guard let url else {
            Log.permissions.error("No System Settings link for \(pane, privacy: .public)")
            return false
        }
        guard openURL(url) else {
            Log.permissions.error("Could not open System Settings for \(pane, privacy: .public)")
            return false
        }
        return true
    }
}
