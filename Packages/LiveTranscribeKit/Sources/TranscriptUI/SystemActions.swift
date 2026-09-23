import AppKit
import Shared

/// Hand-offs to the system: pasteboard, Finder and System Settings.
@MainActor
enum SystemActions {
    private static let microphonePrivacyPane = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"

    static func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func openMicrophoneSettings() {
        guard let url = URL(string: microphonePrivacyPane) else { return }
        NSWorkspace.shared.open(url)
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
