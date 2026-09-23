import Dictation
@testable import DictationUI
import Testing

/// The line under *Listening* and the cancel button's tooltip. Esc cancels only while the
/// shortcut's keyboard tap runs, so neither mentions it otherwise.
@Suite("HUD hint")
struct HUDHintTests {
    @Test func withTheShortcutRunningEscCancels() {
        let running = HotkeyState.running(hotkey: "fn")
        #expect(DictationHUDView.hint(hotkeyState: running, handsFree: false) == "Release fn to finish · esc to cancel")
        #expect(DictationHUDView.hint(hotkeyState: running, handsFree: true) == "Press fn to finish · esc to cancel")
        #expect(DictationHUDView.cancelHelp(hotkeyState: running) == "Cancel (esc)")
    }

    @Test("Without the keyboard tap, the hint names the menu and the × button", arguments: [
        HotkeyState.stopped, .disabled, .needsAccessibility, .failed("The event tap could not be created"),
    ])
    func withoutTheShortcutEscIsNotMentioned(state: HotkeyState) {
        for handsFree in [false, true] {
            let hint = DictationHUDView.hint(hotkeyState: state, handsFree: handsFree)
            #expect(hint == "Finish from the menu bar · × to cancel")
            #expect(!hint.localizedCaseInsensitiveContains("esc"))
        }
        #expect(DictationHUDView.cancelHelp(hotkeyState: state) == "Cancel")
    }

    @Test func aProgressNoticeTakesTheHintsLine() {
        let running = HotkeyState.running(hotkey: "fn")
        let notice = DictationNotice.microphone("Now using AirPods.")
        #expect(DictationHUDView.recordingCaption(progress: notice, hotkeyState: running, handsFree: false) == "Now using AirPods.")
        #expect(
            DictationHUDView.recordingCaption(progress: nil, hotkeyState: running, handsFree: false)
                == "Release fn to finish · esc to cancel"
        )
    }
}
