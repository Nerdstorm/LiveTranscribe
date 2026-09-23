import Foundation

/// Every dictation tunable. Read at each use, so a change in Settings applies to the next
/// dictation without a relaunch.
public struct DictationSettings: Sendable, Equatable {
    /// The dictation hotkey and its gestures are active.
    public var enabled: Bool
    /// The dictation hotkey, as `HotkeyBinding.storageString` ("modifier:fn", "combo:49:control,option").
    public var hotkey: String
    /// The *Undo AI edit* shortcut, stored the same way.
    public var undoHotkey: String
    /// A double tap starts hands-free dictation; the next tap stops it.
    public var handsFreeEnabled: Bool
    /// A press shorter than this is a tap, not push-to-talk.
    public var tapMaxMs: Int
    /// How soon a second tap must follow the first to start hands-free dictation.
    public var doubleTapWindowMs: Int
    /// Shorter recordings are discarded: too short to be speech.
    public var minUtteranceMs: Int
    /// A recording stops growing at this length.
    public var maxRecordingSeconds: Int
    /// Capture stays open between dictations, for an instant start with pre-roll. The microphone
    /// indicator then stays on while the app runs.
    public var keepMicrophoneReady: Bool
    /// Audio from before the key press prepended when the microphone is kept ready.
    public var preRollMs: Int
    /// How long after an insertion *Undo AI edit* still applies.
    public var undoWindowSeconds: Int
    /// Wait after pasting before the clipboard is restored.
    public var pasteRestoreDelayMs: Int
    /// Wait after ⌘Z before inserting the uncleaned text.
    public var undoSettleDelayMs: Int
    /// Longest wait for another app to answer an Accessibility request.
    public var accessibilityTimeoutMs: Int
    /// Wait before reading a field again when an Accessibility insertion seems ignored, for apps
    /// that apply the write a moment after reporting the old value.
    public var accessibilityVerificationDelayMs: Int
    /// How often Accessibility permission is re-checked while the app runs; macOS sends no
    /// notification when it changes.
    public var permissionPollMs: Int
    /// Wait after a burst of settings changes before applying them to dictation.
    public var settingsApplyDelayMs: Int
    /// Most vocabulary terms listed in the cleanup prompt.
    public var vocabularyPromptLimit: Int
    /// How similar a spoken word must be to a vocabulary term to list the term in the prompt.
    public var vocabularySimilarityThreshold: Double
    /// Virtual and aggregate input devices are listed in the microphone picker.
    public var showVirtualInputDevices: Bool
    /// Dictations are kept in the history on this Mac.
    public var historyEnabled: Bool
    /// History older than this many days is deleted; 0 keeps everything.
    public var historyRetentionDays: Int
    /// How long a HUD message stays up.
    public var noticeSeconds: Double

    public init(
        enabled: Bool,
        hotkey: String,
        undoHotkey: String,
        handsFreeEnabled: Bool,
        tapMaxMs: Int,
        doubleTapWindowMs: Int,
        minUtteranceMs: Int,
        maxRecordingSeconds: Int,
        keepMicrophoneReady: Bool,
        preRollMs: Int,
        undoWindowSeconds: Int,
        pasteRestoreDelayMs: Int,
        undoSettleDelayMs: Int,
        accessibilityTimeoutMs: Int,
        accessibilityVerificationDelayMs: Int,
        permissionPollMs: Int,
        settingsApplyDelayMs: Int,
        vocabularyPromptLimit: Int,
        vocabularySimilarityThreshold: Double,
        showVirtualInputDevices: Bool,
        historyEnabled: Bool,
        historyRetentionDays: Int,
        noticeSeconds: Double
    ) {
        self.enabled = enabled
        self.hotkey = hotkey
        self.undoHotkey = undoHotkey
        self.handsFreeEnabled = handsFreeEnabled
        self.tapMaxMs = tapMaxMs
        self.doubleTapWindowMs = doubleTapWindowMs
        self.minUtteranceMs = minUtteranceMs
        self.maxRecordingSeconds = maxRecordingSeconds
        self.keepMicrophoneReady = keepMicrophoneReady
        self.preRollMs = preRollMs
        self.undoWindowSeconds = undoWindowSeconds
        self.pasteRestoreDelayMs = pasteRestoreDelayMs
        self.undoSettleDelayMs = undoSettleDelayMs
        self.accessibilityTimeoutMs = accessibilityTimeoutMs
        self.accessibilityVerificationDelayMs = accessibilityVerificationDelayMs
        self.permissionPollMs = permissionPollMs
        self.settingsApplyDelayMs = settingsApplyDelayMs
        self.vocabularyPromptLimit = vocabularyPromptLimit
        self.vocabularySimilarityThreshold = vocabularySimilarityThreshold
        self.showVirtualInputDevices = showVirtualInputDevices
        self.historyEnabled = historyEnabled
        self.historyRetentionDays = historyRetentionDays
        self.noticeSeconds = noticeSeconds
    }

    public static let defaults = DictationSettings(
        enabled: true,
        hotkey: "modifier:fn",
        undoHotkey: "combo:6:control,option",
        handsFreeEnabled: true,
        tapMaxMs: 300,
        doubleTapWindowMs: 300,
        minUtteranceMs: 300,
        maxRecordingSeconds: 300,
        keepMicrophoneReady: false,
        preRollMs: 300,
        undoWindowSeconds: 30,
        pasteRestoreDelayMs: 250,
        undoSettleDelayMs: 150,
        accessibilityTimeoutMs: 250,
        accessibilityVerificationDelayMs: 75,
        permissionPollMs: 1_000,
        settingsApplyDelayMs: 300,
        vocabularyPromptLimit: 50,
        vocabularySimilarityThreshold: 0.8,
        showVirtualInputDevices: false,
        historyEnabled: true,
        historyRetentionDays: 0,
        noticeSeconds: 2.5
    )

    /// The same settings with every value clamped to a range dictation can run with. Hotkeys are
    /// checked by the Hotkey slice, which falls back to the defaults for anything it cannot parse.
    public func sanitized() -> DictationSettings {
        var copy = self
        copy.tapMaxMs = tapMaxMs.clamped(to: 100...1_000)
        copy.doubleTapWindowMs = doubleTapWindowMs.clamped(to: 100...1_000)
        copy.minUtteranceMs = minUtteranceMs.clamped(to: 0...2_000)
        copy.maxRecordingSeconds = maxRecordingSeconds.clamped(to: 10...1_800)
        copy.preRollMs = preRollMs.clamped(to: 0...2_000)
        copy.undoWindowSeconds = undoWindowSeconds.clamped(to: 5...600)
        copy.pasteRestoreDelayMs = pasteRestoreDelayMs.clamped(to: 50...5_000)
        copy.undoSettleDelayMs = undoSettleDelayMs.clamped(to: 0...2_000)
        copy.accessibilityTimeoutMs = accessibilityTimeoutMs.clamped(to: 50...5_000)
        copy.accessibilityVerificationDelayMs = accessibilityVerificationDelayMs.clamped(to: 0...1_000)
        copy.permissionPollMs = permissionPollMs.clamped(to: 250...10_000)
        copy.settingsApplyDelayMs = settingsApplyDelayMs.clamped(to: 0...2_000)
        copy.vocabularyPromptLimit = vocabularyPromptLimit.clamped(to: 0...200)
        copy.vocabularySimilarityThreshold = vocabularySimilarityThreshold.clamped(to: 0.5...1)
        copy.historyRetentionDays = historyRetentionDays.clamped(to: 0...3_650)
        copy.noticeSeconds = noticeSeconds.clamped(to: 0.5...10)
        return copy
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
