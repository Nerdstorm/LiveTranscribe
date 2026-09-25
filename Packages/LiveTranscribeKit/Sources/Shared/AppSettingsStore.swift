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
    case accessibilityVerificationDelayMs
    case permissionPollMs
    case settingsApplyDelayMs
    case vocabularyPromptLimit
    case vocabularySimilarityThreshold
    case showVirtualInputDevices
    case historyEnabled
    case historyRetentionDays
    case historyPruneIntervalMinutes
    case dictationNoticeSeconds
    /// The chosen microphone's Core Audio UID; absent means the system default input.
    /// Not part of ``AppSettings``: it is read at every Start rather than once at launch.
    case inputDeviceUID
}

extension AppSettingsKey {
    /// What Settings › Advanced shows: the models, segmentation, cleanup tuning and capture
    /// recovery. Its Restore Defaults resets exactly these (``AppSettingsStore/resetToDefaults(_:)``),
    /// so the settings other tabs and windows own (dictation, both shortcuts, the cleanup level,
    /// history, the chosen microphone) are left alone. A setting added to that tab belongs here.
    public static let advancedTab: Set<AppSettingsKey> = [
        .sttModel, .llmModel, .vadModel, .cleanupEnabled, .cleanupAdapterEnabled,
        .vadSilenceMs, .vadSpeechThreshold, .vadPreRollMs, .vadMinSpeechMs, .maxSegmentSeconds,
        .partialIntervalMs,
        .contextSegments, .cleanupTimeoutSeconds, .cleanupQueueCapacity,
        .gpuCacheLimitMB, .captureRestartAttempts, .captureRestartDelaySeconds, .captureMaxRestartsPerMinute,
    ]
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

    /// Repairs settings that earlier versions stored without the user choosing them. Call it at
    /// launch, before ``load()``. Each repair runs once per install.
    ///
    /// Before 0.2.0, Settings › Advanced saved a model field's text as soon as the field gained
    /// focus, so opening the tab stored the models that were the defaults then. A stored model
    /// equal to its current default only pins it against a later change, so it is removed. So is
    /// the speech model that 0.1.x had as its default: an install that stored it would otherwise
    /// never move to the new one. Anyone who sets it again after this keeps it.
    public func migrate() {
        let applied = defaults.integer(forKey: Self.migrationsKey)
        if applied < 1 {
            let current = Self.dictionary(from: .defaults)
            let formerDefaults: [AppSettingsKey: String] = [.sttModel: "mlx-community/parakeet-tdt-0.6b-v3"]
            for key in [AppSettingsKey.sttModel, .llmModel, .vadModel] {
                let stored = defaults.string(forKey: key.rawValue)
                if stored == current[key.rawValue] as? String || stored == formerDefaults[key] {
                    defaults.removeObject(forKey: key.rawValue)
                }
            }
        }
        if applied < Self.migrationCount {
            defaults.set(Self.migrationCount, forKey: Self.migrationsKey)
        }
    }

    /// How many of ``migrate()``'s repairs this install has had. Not a setting.
    private static let migrationsKey = "settingsMigrations"
    private static let migrationCount = 1

    /// Reads the current settings, sanitised to runnable ranges. An unset key reads as its
    /// default.
    ///
    /// A pure read: it never registers or writes anything, so it is safe to call on every use and
    /// from a `UserDefaults.didChangeNotification` observer. (Registering posts that
    /// notification, so a read that registered would re-trigger its own observer forever.)
    public func load() -> AppSettings {
        let d = defaults
        let fallback = Self.dictionary(from: .defaults)
        func isSet(_ key: AppSettingsKey) -> Bool { d.object(forKey: key.rawValue) != nil }
        func string(_ key: AppSettingsKey) -> String {
            isSet(key) ? d.string(forKey: key.rawValue) ?? "" : fallback[key.rawValue] as? String ?? ""
        }
        func int(_ key: AppSettingsKey) -> Int {
            isSet(key) ? d.integer(forKey: key.rawValue) : (fallback[key.rawValue] as? NSNumber)?.intValue ?? 0
        }
        func double(_ key: AppSettingsKey) -> Double {
            isSet(key) ? d.double(forKey: key.rawValue) : (fallback[key.rawValue] as? NSNumber)?.doubleValue ?? 0
        }
        func bool(_ key: AppSettingsKey) -> Bool {
            isSet(key) ? d.bool(forKey: key.rawValue) : (fallback[key.rawValue] as? NSNumber)?.boolValue ?? false
        }

        return AppSettings(
            sttModel: string(.sttModel),
            llmModel: string(.llmModel),
            vadModel: string(.vadModel),
            cleanupEnabled: bool(.cleanupEnabled),
            cleanupAdapterEnabled: bool(.cleanupAdapterEnabled),
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
                accessibilityVerificationDelayMs: int(.accessibilityVerificationDelayMs),
                permissionPollMs: int(.permissionPollMs),
                settingsApplyDelayMs: int(.settingsApplyDelayMs),
                vocabularyPromptLimit: int(.vocabularyPromptLimit),
                vocabularySimilarityThreshold: double(.vocabularySimilarityThreshold),
                showVirtualInputDevices: bool(.showVirtualInputDevices),
                historyEnabled: bool(.historyEnabled),
                historyRetentionDays: int(.historyRetentionDays),
                historyPruneIntervalMinutes: int(.historyPruneIntervalMinutes),
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

    /// Stores the text of a Settings field, such as a model's repository. A text field writes its
    /// text back as soon as it gains focus, so text equal to the current value is ignored, and
    /// text equal to the default removes the stored value. Either way the setting keeps following
    /// the default, including a later version's new one.
    public func setText(_ text: String, for key: AppSettingsKey) {
        let defaultText = Self.dictionary(from: .defaults)[key.rawValue] as? String
        guard text != (defaults.string(forKey: key.rawValue) ?? defaultText) else { return }
        if text == defaultText {
            defaults.removeObject(forKey: key.rawValue)
        } else {
            defaults.set(text, forKey: key.rawValue)
        }
    }

    /// Removes the stored values of `keys`, so their registered defaults apply again; every
    /// other setting stays as it is. A Restore Defaults button passes the keys its own screen
    /// shows, such as ``AppSettingsKey/advancedTab``, so it never resets what the user set
    /// somewhere else.
    public func resetToDefaults(_ keys: Set<AppSettingsKey>) {
        for key in keys {
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
            .accessibilityVerificationDelayMs: s.dictation.accessibilityVerificationDelayMs,
            .permissionPollMs: s.dictation.permissionPollMs,
            .settingsApplyDelayMs: s.dictation.settingsApplyDelayMs,
            .vocabularyPromptLimit: s.dictation.vocabularyPromptLimit,
            .vocabularySimilarityThreshold: s.dictation.vocabularySimilarityThreshold,
            .showVirtualInputDevices: s.dictation.showVirtualInputDevices,
            .historyEnabled: s.dictation.historyEnabled,
            .historyRetentionDays: s.dictation.historyRetentionDays,
            .historyPruneIntervalMinutes: s.dictation.historyPruneIntervalMinutes,
            .dictationNoticeSeconds: s.dictation.noticeSeconds,
        ]
        return Dictionary(uniqueKeysWithValues: values.map { ($0.key.rawValue, $0.value) })
    }
}
