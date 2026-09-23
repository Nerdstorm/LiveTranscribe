import Foundation
import Shared
import Testing

@Suite("AppSettings")
struct AppSettingsTests {
    private func makeStore() -> (AppSettingsStore, String) {
        let suite = "LiveTranscribeTests.\(UUID().uuidString)"
        return (AppSettingsStore(suiteName: suite), suite)
    }

    @Test func unsetKeysReadAsDefaults() {
        let (store, suite) = makeStore()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        #expect(store.load() == AppSettings.defaults)
    }

    /// Registering defaults posts `UserDefaults.didChangeNotification`; the app applies settings
    /// from an observer of that notification, so a load that registered would re-trigger itself
    /// without end (it crashed the app at launch).
    @Test func loadingNeverRegistersOrWrites() {
        let (store, suite) = makeStore()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        _ = store.load()
        // The registration domain is shared by every UserDefaults in the process.
        let registered = UserDefaults.standard.volatileDomain(forName: UserDefaults.registrationDomain)
        #expect(registered[AppSettingsKey.dictationHotkey.rawValue] == nil)
        #expect(UserDefaults(suiteName: suite)?.persistentDomain(forName: suite)?.isEmpty ?? true)
    }

    @Test func savedSettingsRoundTrip() {
        let (store, suite) = makeStore()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        var settings = AppSettings.defaults
        settings.llmModel = "mlx-community/Qwen3-0.6B-4bit"
        settings.cleanupEnabled = false
        settings.cleanupAdapterEnabled = false
        settings.cleanupLevel = .high
        settings.vadSilenceMs = 800
        settings.cleanupTimeoutSeconds = 2.5
        store.save(settings)
        #expect(store.load() == settings)
    }

    @Test func resetRestoresDefaults() {
        let (store, suite) = makeStore()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        var settings = AppSettings.defaults
        settings.contextSegments = 7
        settings.dictation.undoWindowSeconds = 60
        store.save(settings)
        store.resetToDefaults([.contextSegments, .undoWindowSeconds])
        #expect(store.load() == AppSettings.defaults)
    }

    /// Settings › Advanced resets only what it shows; the dictation settings, both shortcuts, the
    /// cleanup level and history are set on other tabs and must survive its Restore Defaults.
    @Test func restoringTheAdvancedTabResetsOnlyItsOwnSettings() {
        let (store, suite) = makeStore()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        var advanced = AppSettings.defaults
        advanced.sttModel = "example/stt"
        advanced.llmModel = "example/llm"
        advanced.vadModel = "example/vad"
        advanced.cleanupEnabled = false
        advanced.cleanupAdapterEnabled = false
        advanced.vadSilenceMs = 900
        advanced.vadSpeechThreshold = 0.7
        advanced.vadPreRollMs = 400
        advanced.vadMinSpeechMs = 300
        advanced.maxSegmentSeconds = 30
        advanced.partialIntervalMs = 500
        advanced.contextSegments = 7
        advanced.cleanupTimeoutSeconds = 2.5
        advanced.cleanupQueueCapacity = 4
        advanced.gpuCacheLimitMB = 1_024
        advanced.captureRestartAttempts = 2
        advanced.captureRestartDelaySeconds = 3
        advanced.captureMaxRestartsPerMinute = 12
        var elsewhere = AppSettings.defaults
        elsewhere.cleanupLevel = .high
        elsewhere.dictation.enabled = false
        elsewhere.dictation.hotkey = "modifier:rightOption"
        elsewhere.dictation.undoHotkey = "combo:7:control,option"
        elsewhere.dictation.handsFreeEnabled = false
        elsewhere.dictation.keepMicrophoneReady = true
        elsewhere.dictation.undoWindowSeconds = 60
        elsewhere.dictation.historyEnabled = false
        elsewhere.dictation.historyRetentionDays = 30
        elsewhere.dictation.historyPruneIntervalMinutes = 15
        var both = advanced
        both.cleanupLevel = elsewhere.cleanupLevel
        both.dictation = elsewhere.dictation
        store.save(both)
        store.setInputDeviceUID("00-11-22:input")
        #expect(store.load() == both, "every value above is in range, so the check below means something")

        store.resetToDefaults(AppSettingsKey.advancedTab)

        #expect(store.load() == elsewhere)
        #expect(store.inputDeviceUID == "00-11-22:input")
    }

    /// Only the keys passed are removed; everything else stays stored.
    @Test func resettingKeysRemovesOnlyThoseKeys() throws {
        let (store, suite) = makeStore()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        store.save(AppSettings.defaults)
        store.setInputDeviceUID("00-11-22:input")

        store.resetToDefaults(AppSettingsKey.advancedTab)

        let stored = try #require(UserDefaults(suiteName: suite)?.persistentDomain(forName: suite))
        let kept = Set(AppSettingsKey.allCases.filter { stored[$0.rawValue] != nil })
        #expect(kept == Set(AppSettingsKey.allCases).subtracting(AppSettingsKey.advancedTab))
    }

    /// Settings › Advanced shows every top-level ``AppSettings`` value but the cleanup level
    /// (chosen in General and the menu); the dictation settings live on other tabs. A new
    /// top-level setting fails this until it is added to the tab and its key set, or excluded
    /// here on purpose.
    @Test func theAdvancedTabIsEveryTopLevelSettingButTheCleanupLevel() {
        let topLevel = Set(Mirror(reflecting: AppSettings.defaults).children.compactMap(\.label))
        #expect(Set(AppSettingsKey.advancedTab.map(\.rawValue)) == topLevel.subtracting(["cleanupLevel", "dictation"]))
    }

    @Test func sanitizedClampsOutOfRangeValues() {
        var settings = AppSettings.defaults
        settings.sttModel = "   "
        settings.vadSilenceMs = 5
        settings.maxSegmentSeconds = 500
        settings.partialIntervalMs = -1
        settings.cleanupQueueCapacity = 0
        let sanitized = settings.sanitized()
        #expect(sanitized.sttModel == AppSettings.defaults.sttModel)
        #expect(sanitized.vadSilenceMs == 100)
        #expect(sanitized.maxSegmentSeconds == 60)
        #expect(sanitized.partialIntervalMs == 0)
        #expect(sanitized.cleanupQueueCapacity == 1)
    }

    @Test func restartTunablesAreClamped() {
        var settings = AppSettings.defaults
        settings.captureRestartDelaySeconds = -10
        settings.captureMaxRestartsPerMinute = 0
        #expect(settings.sanitized().captureRestartDelaySeconds == 0)
        #expect(settings.sanitized().captureMaxRestartsPerMinute == 1)
    }

    @Test func dictationSettingsRoundTrip() {
        let (store, suite) = makeStore()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        var settings = AppSettings.defaults
        settings.dictation.enabled = false
        settings.dictation.hotkey = "modifier:rightOption"
        settings.dictation.handsFreeEnabled = false
        settings.dictation.keepMicrophoneReady = true
        settings.dictation.historyEnabled = false
        settings.dictation.historyRetentionDays = 30
        settings.dictation.historyPruneIntervalMinutes = 15
        settings.dictation.vocabularySimilarityThreshold = 0.9
        settings.dictation.noticeSeconds = 4
        store.save(settings)
        #expect(store.load() == settings)
    }

    @Test func dictationDefaultsMatchTheDesign() {
        let d = AppSettings.defaults.dictation
        #expect(d.enabled && d.handsFreeEnabled && d.historyEnabled)
        #expect(d.hotkey == "modifier:fn")
        #expect(d.undoHotkey == "combo:6:control,option")
        #expect(d.historyRetentionDays == 0, "history keeps everything unless the user sets a limit")
        #expect(d.historyPruneIntervalMinutes == 60)
        #expect(!d.keepMicrophoneReady && !d.showVirtualInputDevices)
        #expect(d.undoWindowSeconds == 30 && d.vocabularyPromptLimit == 50)
        #expect(d.sanitized() == d)
    }

    @Test func dictationTunablesAreClamped() {
        var settings = AppSettings.defaults
        settings.dictation.tapMaxMs = 5
        settings.dictation.undoWindowSeconds = 0
        settings.dictation.historyRetentionDays = -3
        settings.dictation.vocabularySimilarityThreshold = 2
        let sanitized = settings.sanitized().dictation
        #expect(sanitized.tapMaxMs == 100)
        #expect(sanitized.undoWindowSeconds == 5)
        #expect(sanitized.historyRetentionDays == 0)
        #expect(sanitized.vocabularySimilarityThreshold == 1)
    }

    /// A zero interval would prune in a tight loop; more than a day would outlast a one-day
    /// retention by too much.
    @Test func thePruneIntervalIsClamped() {
        var settings = AppSettings.defaults
        settings.dictation.historyPruneIntervalMinutes = 0
        #expect(settings.sanitized().dictation.historyPruneIntervalMinutes == 1)
        settings.dictation.historyPruneIntervalMinutes = 10_000
        #expect(settings.sanitized().dictation.historyPruneIntervalMinutes == 1_440)
    }

    @Test func unknownCleanupLevelReadsAsTheDefault() {
        let (store, suite) = makeStore()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        UserDefaults(suiteName: suite)?.set("extreme", forKey: AppSettingsKey.cleanupLevel.rawValue)
        #expect(store.load().cleanupLevel == .medium)
    }

    @Test func inputDeviceChoiceRoundTrips() {
        let (store, suite) = makeStore()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        #expect(store.inputDeviceUID == nil, "unset means the system default input")
        store.setInputDeviceUID("BuiltInMicrophoneDevice")
        #expect(store.inputDeviceUID == "BuiltInMicrophoneDevice")
        store.setInputDeviceUID("")
        #expect(store.inputDeviceUID == nil)
    }

    @Test func restoringDefaultsKeepsTheChosenMicrophone() {
        let (store, suite) = makeStore()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        var settings = AppSettings.defaults
        settings.vadSilenceMs = 900
        store.save(settings)
        store.setInputDeviceUID("00-11-22:input")
        store.resetToDefaults(AppSettingsKey.advancedTab)
        #expect(store.load() == AppSettings.defaults)
        #expect(store.inputDeviceUID == "00-11-22:input", "the microphone is chosen in the main window, not in Settings")
    }

    @Test func defaultsAreAlreadySanitized() {
        #expect(AppSettings.defaults.sanitized() == AppSettings.defaults)
    }
}
