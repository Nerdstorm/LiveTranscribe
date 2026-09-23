import Capture
import Dictation
import Hotkey
import Session
import Shared

/// The one thing the menu bar says about dictation. The status line at the top of the menu, the
/// menu bar icon and the icon's VoiceOver label all come from it, so they never disagree.
enum MenuBarIndicator: Equatable, Sendable {
    /// Waiting for the hotkey, named as the user sees it ("fn (🌐)", "⌃⌥Space").
    case ready(hotkey: String)
    case recording(handsFree: Bool)
    case processing
    /// The hotkey needs Accessibility access before it can start.
    case needsAccessibility
    /// Microphone access was refused, so nothing can be recorded.
    case needsMicrophone
    /// The hotkey could not start for another reason.
    case hotkeyFailed(String)
    /// The speech models failed to load.
    case modelsFailed(String)
    /// The speech models are loading; `percent` is set while one downloads.
    case modelsLoading(percent: Int?)
    case modelsNotLoaded
    /// The live transcript has the microphone; the two don't run at once.
    case liveTranscriptRunning
    /// The dictation hotkey is turned off in Settings, or has not started.
    case off

    /// Longest error detail shown in the menu. A menu is as wide as its widest item, so a long
    /// system message would stretch the whole menu.
    private static let detailLimit = 80

    /// The status line at the top of the menu.
    var statusText: String {
        switch self {
        case .ready(let hotkey): "Hold \(hotkey) to dictate"
        case .recording(let handsFree): handsFree ? "Listening, hands-free…" : "Listening…"
        case .processing: "Transcribing…"
        case .needsAccessibility: "Dictation needs Accessibility access"
        case .needsMicrophone: "Dictation needs microphone access"
        case .hotkeyFailed(let detail): "The dictation shortcut couldn't start: \(Self.shortened(detail))"
        case .modelsFailed(let detail): "Speech-to-text isn't available: \(Self.shortened(detail))"
        case .modelsLoading(let percent?): "Downloading speech models… \(percent)%"
        case .modelsLoading(nil): "Loading speech models…"
        case .modelsNotLoaded: "Speech models aren't loaded"
        case .liveTranscriptRunning: "Stop the live transcript to dictate"
        case .off: "Dictation is off"
        }
    }

    /// The menu bar icon: an SF Symbol from SF Symbols 3 or earlier, so it exists on macOS 14,
    /// drawn as a template image like every menu bar icon.
    var symbolName: String {
        switch self {
        case .ready: "waveform"
        case .recording: "mic.fill"
        case .processing: "ellipsis.circle"
        case .needsAccessibility, .needsMicrophone, .hotkeyFailed, .modelsFailed: "exclamationmark.triangle"
        case .modelsLoading, .modelsNotLoaded: "arrow.down.circle"
        case .liveTranscriptRunning: "captions.bubble"
        case .off: "mic.slash"
        }
    }

    /// What VoiceOver reads for the menu bar icon.
    var accessibilityLabel: String {
        let state = switch self {
        case .ready: "ready"
        case .recording: "listening"
        case .processing: "transcribing"
        case .needsAccessibility, .needsMicrophone, .hotkeyFailed, .modelsFailed: "needs attention"
        case .modelsLoading, .modelsNotLoaded: "loading speech models"
        case .liveTranscriptRunning: "live transcript on"
        case .off: "dictation off"
        }
        return "Live Transcribe, \(state)"
    }

    /// Something is wrong that the user can fix.
    var needsAttention: Bool {
        switch self {
        case .needsAccessibility, .needsMicrophone, .hotkeyFailed, .modelsFailed: true
        default: false
        }
    }

    /// `text` on one line, cut at ``detailLimit`` characters with an ellipsis.
    static func shortened(_ text: String) -> String {
        let singleLine = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        guard singleLine.count > detailLimit else { return singleLine }
        return singleLine.prefix(detailLimit - 1).trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// Everything the menu shows and allows, derived from dictation, the hotkey, the speech models
/// and the microphone permission.
///
/// Pure, so every combination is unit-tested; ``MenuBarContent`` and ``MenuBarLabel`` only
/// render it.
struct MenuBarStatus: Equatable, Sendable {
    let indicator: MenuBarIndicator
    /// "Start Dictation" or "Stop Dictation".
    let toggleTitle: String
    let canToggleDictation: Bool
    /// *Cancel Dictation* is listed only while there is something to cancel.
    let canCancel: Bool
    /// *Undo AI Edit* applies only between dictations, and only once something was dictated.
    let canUndo: Bool
    /// *Copy Last Dictation* has something to copy.
    let canCopyLastDictation: Bool

    /// - Parameter hasLastDictation: the controller has a last dictation (`lastText` is set).
    ///   Without one there is nothing to copy, and nothing to undo either: the controller keeps
    ///   what it can undo only for a dictation that produced text.
    init(
        phase: DictationController.Phase,
        hotkey: HotkeyState,
        session: SessionPhase,
        modelProgress: [ModelLoadProgress],
        microphone: MicrophonePermissionStatus,
        hasLastDictation: Bool
    ) {
        indicator = Self.indicator(
            phase: phase, hotkey: hotkey, session: session, modelProgress: modelProgress, microphone: microphone
        )
        canCopyLastDictation = hasLastDictation
        switch phase {
        case .idle:
            toggleTitle = "Start Dictation"
            // The controller would refuse with a message; disabling says so before the click.
            canToggleDictation = Self.dictationCanStart(session: session)
            canCancel = false
            canUndo = hasLastDictation
        case .recording:
            toggleTitle = "Stop Dictation"
            canToggleDictation = true
            canCancel = true
            canUndo = false
        case .processing:
            toggleTitle = "Stop Dictation"
            canToggleDictation = false
            canCancel = true
            canUndo = false
        }
    }

    /// What the status line says. A dictation in progress comes first (one started from the menu
    /// runs even with the shortcut off), then dictation turned off in Settings, then problems the
    /// user can fix, then the models, then the hotkey.
    ///
    /// Turned off outranks the rest because none of it applies: telling someone who switched
    /// dictation off to stop the live transcript, or that it needs a permission, sends them to fix
    /// something that would not turn it back on.
    static func indicator(
        phase: DictationController.Phase,
        hotkey: HotkeyState,
        session: SessionPhase,
        modelProgress: [ModelLoadProgress],
        microphone: MicrophonePermissionStatus
    ) -> MenuBarIndicator {
        switch phase {
        case .recording(let handsFree): return .recording(handsFree: handsFree)
        case .processing: return .processing
        case .idle: break
        }
        if hotkey == .disabled { return .off }
        if hotkey == .needsAccessibility { return .needsAccessibility }
        if microphone == .denied { return .needsMicrophone }
        if case .failed(let detail) = hotkey { return .hotkeyFailed(detail) }
        switch session {
        case .failed(.modelLoadFailed(_, let message)): return .modelsFailed(message)
        case .loading: return .modelsLoading(percent: downloadPercent(modelProgress))
        case .notLoaded: return .modelsNotLoaded
        case .listening, .stopping: return .liveTranscriptRunning
        case .ready, .failed: break
        }
        switch hotkey {
        case .running(let name): return .ready(hotkey: name)
        case .disabled, .stopped, .needsAccessibility, .failed: return .off
        }
    }

    /// Whether the speech models are loaded and the live transcript is not using the microphone.
    /// A live transcript that failed to capture or save still leaves the models loaded.
    static func dictationCanStart(session: SessionPhase) -> Bool {
        switch session {
        case .ready, .failed(.microphonePermissionDenied), .failed(.audioCaptureFailed), .failed(.persistenceFailed):
            true
        case .notLoaded, .loading, .listening, .stopping, .failed(.modelLoadFailed):
            false
        }
    }

    /// The download furthest from done, as a whole percentage; `nil` when nothing is
    /// downloading or the download's size is unknown.
    static func downloadPercent(_ progress: [ModelLoadProgress]) -> Int? {
        let fractions = progress.compactMap { $0.stage == .downloading ? $0.fractionCompleted : nil }
        return fractions.min().map { Int(($0 * 100).rounded(.down)) }
    }

    /// "Undo AI Edit (⌃⌥Z)", naming the shortcut only while the hotkey monitor is running it.
    ///
    /// Stored values are read as the controller reads them: an unreadable binding falls back to
    /// the default, and an undo binding the monitor ignores (the same as the dictation hotkey, or
    /// a lone modifier) is not shown.
    static func undoTitle(undoHotkey: String, dictationHotkey: String, hotkey: HotkeyState) -> String {
        let title = "Undo AI Edit"
        guard case .running = hotkey else { return title }
        let dictation = HotkeyBinding(storageString: dictationHotkey) ?? .defaultDictation
        let undo = HotkeyBinding(storageString: undoHotkey) ?? .defaultUndo
        guard let effective = HotkeyMatcher.effectiveUndoBinding(undo, dictation: dictation) else { return title }
        return "\(title) (\(effective.displayName))"
    }
}
