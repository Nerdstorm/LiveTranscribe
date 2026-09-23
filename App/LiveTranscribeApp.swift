import SwiftUI
import TranscriptUI

@main
struct LiveTranscribeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Live Transcribe", id: "main") {
            TranscriptWindow(model: appDelegate.composition.viewModel)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 440, height: 520)

        Settings {
            SettingsView()
        }
    }
}
