import AppKit
import ApplicationServices
import Shared

/// Whether this app may control the computer: needed for the dictation hotkey (an active event
/// tap), for inserting text through the Accessibility API, and for posting ⌘V and ⌘Z.
public protocol AccessibilityPermissionProviding: Sendable {
    func isGranted() -> Bool
    /// Whether macOS lets this app post keystrokes: the ⌘V of a paste and the ⌘Z of undo.
    ///
    /// It comes with Accessibility, but a running app can be trusted for Accessibility and still
    /// be refused here. That was seen after the app's Accessibility entry was removed and added
    /// again while it ran, so the app offers to reopen, to be checked afresh at launch.
    func canPostKeystrokes() -> Bool
    /// Shows the system alert that offers to open System Settings. macOS shows it at most once
    /// per launch, and never once access is granted.
    func prompt()
    /// The current state, then each change. There is no reliable notification for a change, so
    /// the state is also polled.
    func changes() -> AsyncStream<Bool>
}

/// The system (TCC) Accessibility permission.
///
/// The grant is tied to the app's code signature. An ad-hoc signed build gets a new signature
/// every time it is rebuilt, and macOS then keeps showing the old entry as switched on while
/// refusing access; removing the entry and adding the app again fixes it. Builds signed with a
/// certificate (Apple Development locally, see `Config/Signing.xcconfig`, or Developer ID) keep
/// their grant across rebuilds and updates.
public struct SystemAccessibilityPermission: AccessibilityPermissionProviding {
    private let pollInterval: Duration

    /// - Parameter pollInterval: how often ``changes()`` checks the state.
    public init(pollInterval: Duration) {
        self.pollInterval = pollInterval
    }

    public func isGranted() -> Bool {
        AXIsProcessTrusted()
    }

    public func canPostKeystrokes() -> Bool {
        CGPreflightPostEventAccess()
    }

    public func prompt() {
        // The value of kAXTrustedCheckOptionPrompt, which Swift 6 imports as shared mutable state.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        let granted = AXIsProcessTrustedWithOptions(options)
        Log.permissions.info("Accessibility prompt requested; granted: \(granted)")
    }

    public func changes() -> AsyncStream<Bool> {
        PermissionPoller(interval: pollInterval, check: { AXIsProcessTrusted() }).states()
    }
}

/// Polls a permission check and yields the state when it changes, starting with the current one.
struct PermissionPoller: Sendable {
    let interval: Duration
    let check: @Sendable () -> Bool

    func states() -> AsyncStream<Bool> {
        let interval = interval
        let check = check
        return AsyncStream { continuation in
            let task = Task {
                var last: Bool?
                while !Task.isCancelled {
                    let current = check()
                    if current != last {
                        if last != nil {
                            Log.permissions.info("Permission changed; granted: \(current)")
                        }
                        last = current
                        continuation.yield(current)
                    }
                    do {
                        try await Task.sleep(for: interval)
                    } catch {
                        break
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
