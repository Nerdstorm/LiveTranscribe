import DictationUI
import SwiftUI

/// A menu bar app: dictation runs from anywhere, and the transcript, history, Settings and
/// setup windows open from the menu (see ``WindowPresenter``).
@main
struct LiveTranscribeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(context: appDelegate.composition.dictationUI)
        } label: {
            MenuBarLabel(context: appDelegate.composition.dictationUI)
        }
        .menuBarExtraStyle(.menu)
        .commands {
            // The main menu shows only while a window is open; its Settings item opens ours.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { appDelegate.presenter.showSettings(tab: nil) }
                    .keyboardShortcut(",")
            }
        }
    }
}
