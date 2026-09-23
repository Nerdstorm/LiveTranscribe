import Foundation
import os

/// One run of a monitor: matches each key event against the bindings, delivers what it means to
/// the stream, and says whether the tap should swallow the key.
///
/// Kept apart from the event tap so everything but the Core Graphics calls can be tested with
/// plain values. Safe to call from any thread: the tap calls ``route(_:)`` on its own thread
/// while the dictation flow turns Esc capture on and off from another, so all mutable state
/// sits behind one lock. Events are yielded while holding it, so they arrive in key order.
final class HotkeyEventRouter: Sendable {
    private struct State: Sendable {
        var matcher: HotkeyMatcher
        var capturingEscape: Bool
    }

    private let state: OSAllocatedUnfairLock<State>
    private let continuation: AsyncStream<HotkeyEvent>.Continuation

    init(
        binding: HotkeyBinding,
        undoBinding: HotkeyBinding?,
        capturingEscape: Bool,
        continuation: AsyncStream<HotkeyEvent>.Continuation
    ) {
        let matcher = HotkeyMatcher(binding: binding, undoBinding: undoBinding)
        state = OSAllocatedUnfairLock(initialState: State(matcher: matcher, capturingEscape: capturingEscape))
        self.continuation = continuation
    }

    /// Handles one key event. Returns `true` when the tap should swallow it.
    func route(_ event: KeyEventInfo) -> Bool {
        let continuation = continuation
        return state.withLock { state in
            let match = state.matcher.match(event, capturingEscape: state.capturingEscape)
            for hotkeyEvent in match.events {
                continuation.yield(hotkeyEvent)
            }
            return match.consumes
        }
    }

    func setCapturingEscape(_ capturing: Bool) {
        state.withLock { $0.capturingEscape = capturing }
    }

    /// Reconciles with the keyboard after the tap missed events, delivering a release the tap
    /// never saw. See ``HotkeyMatcher/resynchronize(isKeyDown:modifierFlags:)``.
    func resynchronize(isKeyDown: @escaping @Sendable (UInt16) -> Bool, modifierFlags: KeyEventFlags) {
        let continuation = continuation
        state.withLock { state in
            if state.matcher.resynchronize(isKeyDown: isKeyDown, modifierFlags: modifierFlags) == .hotkeyUp {
                continuation.yield(.released)
            }
        }
    }

    /// Ends the stream. Events routed afterwards are still matched, but no longer delivered.
    func finish() {
        continuation.finish()
    }
}
