import Foundation

/// UserDefaults keys for ``AppSettings``. The Settings window binds to the same keys.
public enum AppSettingsKey: String, CaseIterable, Sendable {
    case sttModel
    case llmModel
    case vadModel
    case cleanupEnabled
    case cleanupAdapterEnabled
    case cleanupLevel
    case vadSilenceMs
    case vadSpeechThreshold
    case vadPreRollMs
    case vadMinSpeechMs
    case maxSegmentSeconds
    case partialIntervalMs
    case contextSegments
    case cleanupTimeoutSeconds
    case cleanupQueueCapacity
    case gpuCacheLimitMB
    case captureRestartAttempts
    case captureRestartDelaySeconds
    case captureMaxRestartsPerMinute
    case dictationEnabled
    case dictationHotkey
    case undoHotkey
    case handsFreeEnabled
    case hotkeyTapMaxMs
    case hotkeyDoubleTapWindowMs
    case dictationMinUtteranceMs
    case dictationMaxRecordingSeconds
    case keepMicrophoneReady
    case dictationPreRollMs
    case undoWindowSeconds
    case pasteRestoreDelayMs
    case undoSettleDelayMs
    case accessibilityTimeoutMs
    case vocabularyPromptLimit
    case vocabularySimilarityThreshold
    case showVirtualInputDevices
    case historyEnabled
    case historyRetentionDays
    case dictationNoticeSeconds
    /// The chosen microphone's Core Audio UID; absent means the system default input.
    /// Not part of ``AppSettings``: it is read at every Start rather than once at launch.
    case inputDeviceUID
}

/// Loads and saves ``AppSettings`` in UserDefaults, with defaults registered at launch.
public struct AppSettingsStore: Sendable {
    /// `nil` uses the standard defaults; tests pass a throwaway suite.
    private let suiteName: String?

    public init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults {
        suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    /// Registers ``AppSettings/defaults`` so unset keys read as their default values.
    public func registerDefaults() {
        defaults.register(defaults: Self.dictionary(from: .defaults))
    }

    /// Reads the current settings, sanitised to runnable ranges.
    public func load() -> AppSettings {
        registerDefaults()
        let d = defaults
        func string(_ key: AppSettingsKey) -> String { d.string(forKey: key.rawValue) ?? "" }
        func int(_ key: AppSettingsKey) -> Int { d.integer(forKey: key.rawValue) }
        func double(_ key: AppSettingsKey) -> Double { d.double(forKey: key.rawValue) }
        func bool(_ key: AppSettingsKey) -> Bool { d.bool(forKey: key.rawValue) }

        return AppSettings(
            sttModel: string(.sttModel),
            llmModel: string(.llmModel),
            vadModel: string(.vadModel),
            cleanupEnabled: d.bool(forKey: AppSettingsKey.cleanupEnabled.rawValue),
            cleanupAdapterEnabled: d.bool(forKey: AppSettingsKey.cleanupAdapterEnabled.rawValue),
            cleanupLevel: CleanupLevel(rawValue: string(.cleanupLevel)) ?? AppSettings.defaults.cleanupLevel,
            vadSilenceMs: int(.vadSilenceMs),
            vadSpeechThreshold: double(.vadSpeechThreshold),
            vadPreRollMs: int(.vadPreRollMs),
            vadMinSpeechMs: int(.vadMinSpeechMs),
            maxSegmentSeconds: int(.maxSegmentSeconds),
            partialIntervalMs: int(.partialIntervalMs),
            contextSegments: int(.contextSegments),
            cleanupTimeoutSeconds: double(.cleanupTimeoutSeconds),
            cleanupQueueCapacity: int(.cleanupQueueCapacity),
            gpuCacheLimitMB: int(.gpuCacheLimitMB),
            captureRestartAttempts: int(.captureRestartAttempts),
            captureRestartDelaySeconds: double(.captureRestartDelaySeconds),
            captureMaxRestartsPerMinute: int(.captureMaxRestartsPerMinute),
            dictation: DictationSettings(
                enabled: bool(.dictationEnabled),
                hotkey: string(.dictationHotkey),
                undoHotkey: string(.undoHotkey),
                handsFreeEnabled: bool(.handsFreeEnabled),
                tapMaxMs: int(.hotkeyTapMaxMs),
                doubleTapWindowMs: int(.hotkeyDoubleTapWindowMs),
                minUtteranceMs: int(.dictationMinUtteranceMs),
                maxRecordingSeconds: int(.dictationMaxRecordingSeconds),
                keepMicrophoneReady: bool(.keepMicrophoneReady),
                preRollMs: int(.dictationPreRollMs),
                undoWindowSeconds: int(.undoWindowSeconds),
                pasteRestoreDelayMs: int(.pasteRestoreDelayMs),
                undoSettleDelayMs: int(.undoSettleDelayMs),
                accessibilityTimeoutMs: int(.accessibilityTimeoutMs),
                vocabularyPromptLimit: int(.vocabularyPromptLimit),
                vocabularySimilarityThreshold: double(.vocabularySimilarityThreshold),
                showVirtualInputDevices: bool(.showVirtualInputDevices),
                historyEnabled: bool(.historyEnabled),
                historyRetentionDays: int(.historyRetentionDays),
                noticeSeconds: double(.dictationNoticeSeconds)
            )
        ).sanitized()
    }

    /// The selected microphone's UID, or `nil` for the system default input.
    public var inputDeviceUID: String? {
        guard let uid = defaults.string(forKey: AppSettingsKey.inputDeviceUID.rawValue), !uid.isEmpty else {
            return nil
        }
        return uid
    }

    /// Stores the microphone to capture from; `nil` follows the system default input.
    public func setInputDeviceUID(_ uid: String?) {
        if let uid, !uid.isEmpty {
            defaults.set(uid, forKey: AppSettingsKey.inputDeviceUID.rawValue)
        } else {
            defaults.removeObject(forKey: AppSettingsKey.inputDeviceUID.rawValue)
        }
    }

    public func save(_ settings: AppSettings) {
        for (key, value) in Self.dictionary(from: settings) {
            defaults.set(value, forKey: key)
        }
    }

    /// Removes every stored setting so the registered defaults apply again. The chosen
    /// microphone stays: it is picked in the main window, not in Settings.
    public func resetToDefaults() {
        for key in AppSettingsKey.allCases where key != .inputDeviceUID {
            defaults.removeObject(forKey: key.rawValue)
        }
    }

    static func dictionary(from s: AppSettings) -> [String: Any] {
        let values: [AppSettingsKey: Any] = [
            .sttModel: s.sttModel,
            .llmModel: s.llmModel,
            .vadModel: s.vadModel,
            .cleanupEnabled: s.cleanupEnabled,
            .cleanupAdapterEnabled: s.cleanupAdapterEnabled,
            .cleanupLevel: s.cleanupLevel.rawValue,
            .vadSilenceMs: s.vadSilenceMs,
            .vadSpeechThreshold: s.vadSpeechThreshold,
            .vadPreRollMs: s.vadPreRollMs,
            .vadMinSpeechMs: s.vadMinSpeechMs,
            .maxSegmentSeconds: s.maxSegmentSeconds,
            .partialIntervalMs: s.partialIntervalMs,
            .contextSegments: s.contextSegments,
            .cleanupTimeoutSeconds: s.cleanupTimeoutSeconds,
            .cleanupQueueCapacity: s.cleanupQueueCapacity,
            .gpuCacheLimitMB: s.gpuCacheLimitMB,
            .captureRestartAttempts: s.captureRestartAttempts,
            .captureRestartDelaySeconds: s.captureRestartDelaySeconds,
            .captureMaxRestartsPerMinute: s.captureMaxRestartsPerMinute,
            .dictationEnabled: s.dictation.enabled,
            .dictationHotkey: s.dictation.hotkey,
            .undoHotkey: s.dictation.undoHotkey,
            .handsFreeEnabled: s.dictation.handsFreeEnabled,
            .hotkeyTapMaxMs: s.dictation.tapMaxMs,
            .hotkeyDoubleTapWindowMs: s.dictation.doubleTapWindowMs,
            .dictationMinUtteranceMs: s.dictation.minUtteranceMs,
            .dictationMaxRecordingSeconds: s.dictation.maxRecordingSeconds,
            .keepMicrophoneReady: s.dictation.keepMicrophoneReady,
            .dictationPreRollMs: s.dictation.preRollMs,
            .undoWindowSeconds: s.dictation.undoWindowSeconds,
            .pasteRestoreDelayMs: s.dictation.pasteRestoreDelayMs,
            .undoSettleDelayMs: s.dictation.undoSettleDelayMs,
            .accessibilityTimeoutMs: s.dictation.accessibilityTimeoutMs,
            .vocabularyPromptLimit: s.dictation.vocabularyPromptLimit,
            .vocabularySimilarityThreshold: s.dictation.vocabularySimilarityThreshold,
            .showVirtualInputDevices: s.dictation.showVirtualInputDevices,
            .historyEnabled: s.dictation.historyEnabled,
            .historyRetentionDays: s.dictation.historyRetentionDays,
            .dictationNoticeSeconds: s.dictation.noticeSeconds,
        ]
        return Dictionary(uniqueKeysWithValues: values.map { ($0.key.rawValue, $0.value) })
    }
}
