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
    /// The microphone stopped partway through; what was heard before it did was inserted.
    case captureStoppedEarly(afterSeconds: Int)
    case transcriptionFailed(String)
    case recordingTruncated(seconds: Int)
    case undone
    case undoCopiedToClipboard
    case nothingToUndo
    case undoRefused(String)
    case undoFailed
    /// The microphone changed or fell back; the message names the device.
    case microphone(String)
    /// The hotkey was pressed while the last dictation was still being inserted, so nothing was
    /// recorded. It shows while that dictation finishes and again once it has, so its message
    /// is worded to be true at both times.
    case stillProcessing
    /// Dictation was started from the menu while a shortcut is being recorded in Settings.
    case recordingShortcut

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
        case .captureStoppedEarly(let seconds):
            "The microphone stopped after \(Self.duration(seconds: seconds)); the rest wasn't heard"
        case .transcriptionFailed(let detail): detail
        case .recordingTruncated(let seconds): "Recording stopped at \(Self.duration(seconds: seconds)); the rest wasn't heard"
        case .undone: "Restored what you said"
        case .undoCopiedToClipboard: "What you said is on the clipboard: select the edit and press ⌘V"
        case .nothingToUndo: "Nothing to undo"
        case .undoRefused(let reason): reason
        case .undoFailed: "Couldn't undo the edit"
        case .microphone(let message): message
        case .stillProcessing: "Press again to dictate: the last dictation was still being inserted"
        case .recordingShortcut: "Finish recording the shortcut in Settings first"
        }
    }

    /// Shown as a problem rather than as information.
    public var isProblem: Bool {
        switch self {
        case .cancelled, .undone, .nothingToUndo, .nothingHeard, .copiedToClipboard, .undoCopiedToClipboard, .microphone,
             .stillProcessing, .recordingShortcut:
            false
        default:
            true
        }
    }

    /// A length in whole seconds as the HUD says it: "30 s", "1 min", "1 min 30 s".
    ///
    /// Written out rather than formatted for the locale, like every other message, since
    /// dictation is English only.
    static func duration(seconds: Int) -> String {
        let minutes = seconds / 60
        let rest = seconds % 60
        switch (minutes, rest) {
        case (0, _): return "\(rest) s"
        case (_, 0): return "\(minutes) min"
        default: return "\(minutes) min \(rest) s"
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
