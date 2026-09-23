import AppKit

/// Reads a status change aloud with VoiceOver, for changes that happen away from the focused
/// control: a recorded shortcut, a cleared history, a permission that was just granted.
@MainActor
enum SettingsRootAnnouncer {
    static func announce(_ message: String) {
        guard !message.isEmpty, let app = NSApp else { return }
        NSAccessibility.post(
            element: app,
            notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )
    }
}
