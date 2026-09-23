import Foundation

/// Timing for ``HotkeyGesture``. The values come from settings; there are deliberately no
/// defaults here, so the app's choices live in one place.
public struct HotkeyGestureConfiguration: Sendable, Equatable {
    /// A press released sooner than this is a tap; held this long or longer it is push-to-talk.
    public var tapMaxMs: Int
    /// After a tap, a second press within this window starts hands-free recording.
    public var doubleTapWindowMs: Int
    /// Whether a double tap starts hands-free recording. When off, every tap is cancelled.
    public var handsFreeEnabled: Bool

    public init(tapMaxMs: Int, doubleTapWindowMs: Int, handsFreeEnabled: Bool) {
        self.tapMaxMs = max(0, tapMaxMs)
        self.doubleTapWindowMs = max(0, doubleTapWindowMs)
        self.handsFreeEnabled = handsFreeEnabled
    }
}

/// What happened to the hotkey, as the gesture sees it.
public enum HotkeyInput: Sendable, Equatable {
    case pressed
    case released
    /// Esc was pressed.
    case escape
    /// Another key was pressed while a modifier-only hotkey was held.
    case otherKey
    /// The timer from the last ``HotkeyAction/scheduleTimer(ms:)`` ran out.
    case timerFired
}

/// What the dictation flow should do in response to an input.
public enum HotkeyAction: Sendable, Equatable {
    /// Start capturing audio.
    case startRecording
    /// Stop capturing and transcribe, clean up and insert what was said.
    case stopAndProcess
    /// Stop capturing and throw the audio away.
    case cancel
    /// A double tap turned the recording into hands-free: it continues without the key held.
    case enteredHandsFree
    /// Call ``HotkeyGesture/handle(_:atMs:)`` with ``HotkeyInput/timerFired`` after `ms`.
    ///
    /// Every timer asked for must fire exactly once and is never cancelled; timers fire in the
    /// order they were asked for (they all have the same length). `atMs` for the firing should
    /// come from the same clock as the other inputs. A timer left over from an earlier tap is
    /// recognised and ignored.
    case scheduleTimer(ms: Int)
}

/// The push-to-talk gesture as a pure state machine (docs/dictation.md, "Hotkey gestures").
///
/// - Hold for at least `tapMaxMs`, then release: the recording is processed.
/// - Tap, then press again within `doubleTapWindowMs`: hands-free. The second press's release
///   is ignored; the next press stops and processes, and its release is ignored too.
/// - A lone tap is cancelled: too short to be speech.
/// - Esc while recording (held, waiting for a second tap, or hands-free) cancels.
/// - Another key while the hotkey is held (before hands-free) cancels: the user is typing a
///   shortcut. In hands-free the user is expected to type, so other keys are ignored.
///
/// Recording starts on the first press, so audio from the first word is never lost while the
/// gesture decides what the press was. Inputs that make no sense in the current state are
/// ignored, and `startRecording` is never emitted twice without a stop or cancel between.
///
/// Time comes in as `atMs` from one monotonic clock, so the machine is deterministic and needs
/// no real timers: when it needs one it asks with ``HotkeyAction/scheduleTimer(ms:)``.
///
/// The gesture ends at `stopAndProcess`. Cancelling the processing that follows (Esc while
/// transcribing or cleaning up) is the dictation flow's job: here Esc when idle is ignored.
public struct HotkeyGesture: Sendable {
    private enum Phase: Sendable, Equatable {
        case idle
        /// Recording with the key down since `pressedAt`; not yet known to be a hold or a tap.
        case held(pressedAt: Int)
        /// Recording after a tap released at `releasedAt`; a second press makes it hands-free.
        case awaitingSecondPress(releasedAt: Int)
        /// Recording hands-free. `keyDown` is true while the press that started it is still held.
        case handsFree(keyDown: Bool)
    }

    public let configuration: HotkeyGestureConfiguration
    private var phase: Phase = .idle
    /// Timers asked for and not yet fired. Timers are never cancelled, so one from an earlier
    /// tap can still be pending when a new tap waits for its second press.
    private var timersPending = 0

    public init(configuration: HotkeyGestureConfiguration) {
        self.configuration = configuration
    }

    /// Whether audio is being recorded: from `startRecording` until `stopAndProcess` or `cancel`.
    public var isRecording: Bool {
        phase != .idle
    }

    /// Whether the recording continues without the key held.
    public var isHandsFree: Bool {
        if case .handsFree = phase { return true }
        return false
    }

    /// Returns to idle without emitting anything. Timers already asked for may still fire; they
    /// are ignored as usual.
    ///
    /// For when the owner has already stopped or abandoned the recording itself (the monitor
    /// restarted with a new binding, or the flow refused to record), so a release that will
    /// never arrive does not leave the gesture held.
    public mutating func reset() {
        phase = .idle
    }

    /// Advances the machine and returns what to do, in order. Empty when the input is ignored.
    public mutating func handle(_ input: HotkeyInput, atMs now: Int) -> [HotkeyAction] {
        if input == .timerFired {
            timersPending = max(0, timersPending - 1)
        }
        switch (phase, input) {
        case (.idle, .pressed):
            phase = .held(pressedAt: now)
            return [.startRecording]

        case (.held(let pressedAt), .released):
            if now - pressedAt >= configuration.tapMaxMs {
                phase = .idle
                return [.stopAndProcess]
            }
            guard configuration.handsFreeEnabled else {
                phase = .idle
                return [.cancel]
            }
            phase = .awaitingSecondPress(releasedAt: now)
            timersPending += 1
            return [.scheduleTimer(ms: configuration.doubleTapWindowMs)]

        case (.held, .escape), (.held, .otherKey):
            phase = .idle
            return [.cancel]

        case (.awaitingSecondPress(let releasedAt), .pressed):
            if now - releasedAt <= configuration.doubleTapWindowMs {
                phase = .handsFree(keyDown: true)
                return [.enteredHandsFree]
            }
            // The window ran out before its timer was delivered: the first tap was a lone tap,
            // and this press starts a new gesture rather than being lost.
            phase = .held(pressedAt: now)
            return [.cancel, .startRecording]

        case (.awaitingSecondPress(let releasedAt), .timerFired):
            // A timer from an earlier tap must not cut this window short. A timer is ignored
            // only when both signs say it is stale: a later timer is still pending, and this
            // tap's deadline has not passed. If only one says so, the window ends anyway, so a
            // caller whose timer clock differs slightly from `atMs`, or who lost a timer, can
            // never leave a recording running.
            let isStale = timersPending > 0 && now - releasedAt < configuration.doubleTapWindowMs
            guard !isStale else { return [] }
            phase = .idle
            return [.cancel]

        case (.awaitingSecondPress, .escape):
            phase = .idle
            return [.cancel]

        case (.handsFree(keyDown: true), .released):
            phase = .handsFree(keyDown: false)
            return []

        case (.handsFree(keyDown: false), .pressed):
            // Stop on press; the release that follows arrives in idle and is ignored.
            phase = .idle
            return [.stopAndProcess]

        case (.handsFree, .escape):
            phase = .idle
            return [.cancel]

        default:
            // Duplicate presses, releases with nothing held, stale timers, other keys in
            // hands-free or when idle: nothing to do.
            return []
        }
    }
}

extension HotkeyEvent {
    /// The gesture input for a monitor event, or `nil` for ``HotkeyEvent/undo``, which is not
    /// part of the dictation gesture.
    public var gestureInput: HotkeyInput? {
        switch self {
        case .pressed: .pressed
        case .released: .released
        case .escape: .escape
        case .otherKey: .otherKey
        case .undo: nil
        }
    }
}
