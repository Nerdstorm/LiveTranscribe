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

/// Opens System Settings at a permission's pane.
@MainActor
public enum PrivacySettings {
    public static func open(_ permission: RequiredPermission) {
        guard let url = permission.settingsURL else {
            Log.permissions.error("No System Settings link for \(permission.rawValue, privacy: .public)")
            return
        }
        if !NSWorkspace.shared.open(url) {
            Log.permissions.error("Could not open System Settings for \(permission.rawValue, privacy: .public)")
        }
    }
}
