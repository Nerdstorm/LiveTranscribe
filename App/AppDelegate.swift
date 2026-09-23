import AppKit
import Shared

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Upper bound on how long quitting waits for queued segments to be cleaned and saved.
    private static let shutdownGraceSeconds: Double = 15

    let composition = AppComposition()
    private var hasRepliedToTerminate = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
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
