import AppKit
import Dictation

/// Decides which HUD messages VoiceOver announces: each notice once, when it appears, and not
/// again while it stays up and the HUD redraws or moves.
///
/// A notice that goes away and comes back is announced again. The same notice shown twice in a
/// row without going away (say, *Nothing to undo* twice within the notice time) is announced
/// once, like the HUD, which does not change either.
///
/// Only notices the HUD shows are announced, and it shows them only between dictations. Nothing
/// is announced while recording, *Listening* included: VoiceOver speaking while the microphone
/// is open would be dictated along with the user. A notice still set when the next recording
/// starts is dropped, not announced once the microphone is open.
struct HUDAnnouncer {
    private var current: DictationNotice?

    /// The text to announce now, if any; `nil` when there is nothing new.
    ///
    /// - Parameters:
    ///   - notice: the controller's notice.
    ///   - phase: the controller's phase; the HUD shows the notice only while idle.
    mutating func announcement(for notice: DictationNotice?, phase: DictationController.Phase) -> String? {
        let visible = phase == .idle ? notice : nil
        defer { current = visible }
        guard let visible, visible != current else { return nil }
        return visible.message
    }

    /// Reads a message out to VoiceOver users without moving their focus. Does nothing when
    /// VoiceOver is off.
    @MainActor
    static func post(_ message: String) {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )
    }
}
