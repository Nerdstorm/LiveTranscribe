import AppKit
import DictationUI
import Shared

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Upper bound on how long quitting waits for queued segments to be cleaned and saved.
    private static let shutdownGraceSeconds: Double = 15

    let composition = AppComposition()
    private(set) lazy var presenter = WindowPresenter(context: composition.dictationUI)
    private var hasRepliedToTerminate = false

    /// Loads the models and starts dictation at launch, whether or not a window opens, and
    /// walks a first-time user through the permissions dictation needs.
    func applicationDidFinishLaunching(_ notification: Notification) {
        composition.dictationUI.windows = presenter
        composition.start()
        if composition.needsOnboarding {
            presenter.showOnboarding()
        }
    }

    /// The menu bar keeps running with every window closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Opening the app again (Finder, Spotlight, the Dock) shows the transcript.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            presenter.showTranscript()
        }
        return true
    }

    /// Quitting stops capture first (so the microphone is released at once), then waits for the
    /// pipeline to drain and the session file to be flushed.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await composition.shutdown()
            replyToTerminate(sender)
        }
        Task {
            try? await Task.sleep(for: .seconds(Self.shutdownGraceSeconds))
            if !hasRepliedToTerminate {
                Log.app.error("Shutdown did not finish in time; quitting anyway")
            }
            replyToTerminate(sender)
        }
        return .terminateLater
    }

    private func replyToTerminate(_ sender: NSApplication) {
        guard !hasRepliedToTerminate else { return }
        hasRepliedToTerminate = true
        sender.reply(toApplicationShouldTerminate: true)
    }
}
