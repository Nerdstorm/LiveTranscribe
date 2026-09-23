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
        store.save(settings)
        store.resetToDefaults()
        #expect(store.load() == AppSettings.defaults)
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
        store.resetToDefaults()
        #expect(store.load() == AppSettings.defaults)
        #expect(store.inputDeviceUID == "00-11-22:input", "the microphone is chosen in the main window, not in Settings")
    }

    @Test func defaultsAreAlreadySanitized() {
        #expect(AppSettings.defaults.sanitized() == AppSettings.defaults)
    }
}
