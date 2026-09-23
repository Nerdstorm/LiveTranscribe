import AppKit
import Permissions
import Shared

/// Hand-offs to the system: pasteboard, Finder and System Settings.
@MainActor
enum SystemActions {
    static func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// - Returns: Whether System Settings opened.
    static func openMicrophoneSettings() -> Bool {
        PrivacySettings.open(.microphone)
    }

    static func openFolder(_ url: URL) {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            Log.ui.error("Could not create \(url.path, privacy: .private): \(error.localizedDescription, privacy: .public)")
        }
        NSWorkspace.shared.open(url)
    }
}
