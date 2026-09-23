import Foundation

/// Runs async operations one at a time, in the order they arrive.
///
/// A paste owns the pasteboard from its snapshot until its restore. A second paste inside that
/// window (a dictation finishing while *Undo AI edit* pastes, say) would snapshot the first one's
/// text and later "restore" it over the user's clipboard, losing what the user had copied. The
/// paste inserter runs every paste through one of these, so callers cannot overlap them by mistake.
///
/// An operation, once queued, runs to completion even if its caller is cancelled: the caller's
/// cancellation does not reach it, for the same reason ``sleepIgnoringCancellation(milliseconds:)``
/// exists. Callers that must be cancellable check before queueing.
actor SerialQueue {
    /// Completes when the most recently queued operation has finished.
    private var tail: Task<Void, Never>?

    /// Waits for every operation queued earlier, then runs `operation` and returns its value.
    func run<Value: Sendable>(_ operation: @escaping @Sendable () async -> Value) async -> Value {
        let previous = tail
        let current = Task {
            await previous?.value
            return await operation()
        }
        // Set before this method first suspends, so the next caller queues behind this one.
        tail = Task { _ = await current.value }
        return await current.value
    }
}

/// Waits even if the calling task is cancelled.
///
/// For waits that guard a side effect already started (a posted keystroke, an Accessibility write
/// the app may still be applying), where cutting the wait short would do harm. The wait runs in a
/// detached task, which the caller's cancellation does not reach.
func sleepIgnoringCancellation(milliseconds: Int) async {
    guard milliseconds > 0 else { return }
    await Task.detached {
        try? await Task.sleep(for: .milliseconds(milliseconds))
    }.value
}
