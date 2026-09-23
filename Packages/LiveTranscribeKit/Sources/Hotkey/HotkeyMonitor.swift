import Foundation

/// A hotkey event delivered by a ``HotkeyMonitor``.
public enum HotkeyEvent: Sendable, Equatable {
    /// The dictation hotkey went down.
    case pressed
    /// The dictation hotkey went up.
    case released
    /// Esc was pressed. Swallowed only while the monitor is capturing Esc.
    case escape
    /// Another key was pressed while a modifier-only dictation hotkey was held.
    case otherKey
    /// The undo-AI-edit combination was pressed.
    case undo
}

/// Watches the keyboard system-wide for the dictation and undo hotkeys.
///
/// A protocol so the dictation flow can be tested with a fake that emits scripted events,
/// without Accessibility permission or real key presses.
public protocol HotkeyMonitor: AnyObject, Sendable {
    /// Starts watching and returns the events. The stream finishes after ``stop()``; when the
    /// consumer stops listening (its task is cancelled or it drops the stream), the monitor
    /// stops too. An `undoBinding` that cannot be used (a modifier on its own, invalid, or the
    /// same as `binding`) is ignored and undo is off.
    ///
    /// Throws ``HotkeyError/invalidBinding(_:)`` for a combination that fails
    /// ``HotkeyBinding/validate()``, ``HotkeyError/permissionDenied`` when the system refuses the
    /// keyboard tap (Accessibility not granted), and ``HotkeyError/alreadyRunning`` if already
    /// started.
    func start(binding: HotkeyBinding, undoBinding: HotkeyBinding?) throws -> AsyncStream<HotkeyEvent>

    /// Stops watching and finishes the stream. Does nothing when not running.
    func stop()

    /// Whether Esc is swallowed, so it cancels dictation without also reaching the frontmost
    /// app. Turned on while recording or processing, and off otherwise.
    func setCapturingEscape(_ capturing: Bool)
}

/// Why a ``HotkeyMonitor`` could not start.
public enum HotkeyError: LocalizedError, Equatable {
    /// The keyboard event tap could not be created: Accessibility access has not been granted.
    case permissionDenied
    /// The monitor was started while already running.
    case alreadyRunning
    /// The dictation shortcut would capture ordinary typing or a standard shortcut, or could
    /// never fire.
    case invalidBinding(HotkeyBindingError)
    /// The event tap was created but could not be attached to its run loop.
    case startFailed(String)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Live Transcribe needs Accessibility access to use the dictation shortcut. "
                + "Turn it on in System Settings › Privacy & Security › Accessibility."
        case .alreadyRunning:
            "The dictation shortcut is already active."
        case .invalidBinding(let reason):
            "The dictation shortcut can't be used. " + (reason.errorDescription ?? "")
        case .startFailed(let detail):
            "The dictation shortcut could not start: \(detail)"
        }
    }
}
