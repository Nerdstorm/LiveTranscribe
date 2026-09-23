import AppKit
import Shared

/// Quits Live Transcribe and opens it again, for a permission macOS applies to a running app only
/// once it reopens (see ``AccessibilityPermissionProviding/canPostKeystrokes()``).
///
/// A small shell process waits for this one to exit before opening the app, so the new instance
/// never runs beside the old one with a second keyboard tap and microphone. Quitting always
/// finishes: the app delegate replies to termination after its shutdown grace period at the latest.
@MainActor
enum AppRelauncher {
    /// What to do by hand when ``relaunch()`` fails.
    static let failureMessage = "Couldn't reopen Live Transcribe. Quit it from the menu bar, then open it again."

    /// Starts the waiting process, then quits.
    ///
    /// - Returns: `false`, without quitting, when the waiting process could not start.
    static func relaunch() -> Bool {
        let waiter = Process()
        waiter.executableURL = URL(fileURLWithPath: "/bin/sh")
        waiter.arguments = arguments(
            waitingFor: ProcessInfo.processInfo.processIdentifier,
            thenRunning: "/usr/bin/open",
            with: Bundle.main.bundlePath
        )
        do {
            try waiter.run()
        } catch {
            Log.ui.error("Live Transcribe could not reopen itself: \(error.localizedDescription, privacy: .public)")
            return false
        }
        Log.ui.info("Quitting so Live Transcribe reopens")
        NSApp.terminate(nil)
        return true
    }

    /// The shell arguments: wait until `pid` has exited, then run `command` with `argument`.
    ///
    /// Both are passed as positional arguments (`$1`, `$2`), never written into the script, so
    /// any path is safe. The 0.2 s poll only bounds how soon the app reappears after quitting,
    /// so it is not a setting.
    nonisolated static func arguments(waitingFor pid: Int32, thenRunning command: String, with argument: String) -> [String] {
        [
            "-c",
            "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done; exec \"$1\" \"$2\"",
            "reopen-live-transcribe",
            command,
            argument,
        ]
    }
}
