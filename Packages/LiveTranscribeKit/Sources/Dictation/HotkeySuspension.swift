import Foundation

/// A pause of the dictation and undo shortcuts, from ``DictationController/suspendHotkeys()``.
///
/// Whoever pauses the shortcuts holds one of these and calls ``end()`` when it no longer needs
/// the keys. The shortcuts come back once every suspension has ended.
///
/// Ending happens exactly once. A suspension released without ``end()`` (its owner went away on
/// a path that forgot to end it) ends itself shortly after, on the main actor, so the shortcuts
/// can never stay off by mistake.
@MainActor
public final class HotkeySuspension {
    /// Called when the suspension ends; `nil` once it has.
    private var onEnd: (@MainActor @Sendable () -> Void)?

    /// - Parameter onEnd: Called once, when the suspension ends. Public so a view's tests can
    ///   hand out suspensions without a dictation controller.
    public init(onEnd: @escaping @MainActor @Sendable () -> Void) {
        self.onEnd = onEnd
    }

    /// Whether the suspension is still in force.
    public var isActive: Bool { onEnd != nil }

    /// Ends the suspension. Does nothing if it has already ended.
    public func end() {
        let onEnd = self.onEnd
        self.onEnd = nil
        onEnd?()
    }

    deinit {
        // A deinit runs on whichever thread released the last reference, and may run in the middle
        // of a view update, so ending is always deferred to the next turn of the main actor.
        guard let onEnd else { return }
        Task { @MainActor in onEnd() }
    }
}
