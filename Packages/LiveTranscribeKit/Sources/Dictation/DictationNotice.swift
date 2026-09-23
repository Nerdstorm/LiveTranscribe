import Foundation

/// A short message for the HUD after a dictation or an undo.
public enum DictationNotice: Sendable, Equatable {
    case modelsLoading
    case modelsUnavailable(String)
    case liveTranscriptRunning
    case microphoneDenied
    case secureField
    case nothingHeard
    case cancelled
    case copiedToClipboard(app: String?)
    case insertionFailed
    case captureFailed(String)
    case transcriptionFailed(String)
    case recordingTruncated(seconds: Int)
    case undone
    case undoCopiedToClipboard
    case nothingToUndo
    case undoRefused(String)
    case undoFailed

    public var message: String {
        switch self {
        case .modelsLoading: "The speech models are still loading"
        case .modelsUnavailable(let detail): "Speech-to-text isn't available: \(detail)"
        case .liveTranscriptRunning: "Stop the live transcript to dictate"
        case .microphoneDenied: "Allow microphone access in System Settings to dictate"
        case .secureField: "Dictation is off in password fields"
        case .nothingHeard: "Didn't catch that"
        case .cancelled: "Cancelled"
        case .copiedToClipboard(let app):
            if let app { "\(app) didn't accept the text. It's on the clipboard: press ⌘V" } else { "Copied: press ⌘V to paste" }
        case .insertionFailed: "The text couldn't be inserted or copied"
        case .captureFailed(let detail): "The microphone stopped: \(detail)"
        case .transcriptionFailed(let detail): detail
        case .recordingTruncated(let seconds): "Recording stopped at \(seconds / 60) min; the rest wasn't heard"
        case .undone: "Restored what you said"
        case .undoCopiedToClipboard: "What you said is on the clipboard: select the edit and press ⌘V"
        case .nothingToUndo: "Nothing to undo"
        case .undoRefused(let reason): reason
        case .undoFailed: "Couldn't undo the edit"
        }
    }

    /// Shown as a problem rather than as information.
    public var isProblem: Bool {
        switch self {
        case .cancelled, .undone, .nothingToUndo, .nothingHeard, .copiedToClipboard, .undoCopiedToClipboard:
            false
        default:
            true
        }
    }
}

/// Whether dictation can run now; the models belong to the session, which reports this.
public enum DictationReadiness: Sendable, Equatable {
    case ready
    case modelsLoading
    case modelsUnavailable(String)
    /// The live transcript is listening; the two don't run at once.
    case liveTranscriptRunning
}

/// The dictation hotkey's state, for the menu and Settings.
public enum HotkeyState: Sendable, Equatable {
    case stopped
    case disabled
    case running(hotkey: String)
    /// Accessibility is needed for the system-wide keyboard tap.
    case needsAccessibility
    case failed(String)
}
