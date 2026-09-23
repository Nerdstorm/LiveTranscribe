import SwiftUI
import TranscriptUI

/// The menu bar's *Microphone* submenu: System Default, the microphones, and *Show Other Devices*.
///
/// It shows the same items as the live transcript window's microphone menu
/// (``MicrophoneMenuItems``), and Settings › General lists the same rows, so the three pickers
/// always agree. Locked while the live transcript is listening, because the microphone is fixed
/// for a session.
struct MenuMicrophoneSubmenu: View {
    let transcript: TranscriptViewModel
    /// The `showVirtualInputDevices` setting.
    @Binding var showOtherDevices: Bool

    var body: some View {
        Menu("Microphone") {
            MicrophoneMenuItems(model: transcript, showOtherDevices: $showOtherDevices)
        }
        .disabled(!transcript.canChangeInputDevice)
    }
}
