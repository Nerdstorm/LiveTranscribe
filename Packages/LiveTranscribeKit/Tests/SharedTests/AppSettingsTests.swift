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

    @Test func savedSettingsRoundTrip() {
        let (store, suite) = makeStore()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        var settings = AppSettings.defaults
        settings.llmModel = "mlx-community/Qwen3-0.6B-4bit"
        settings.cleanupEnabled = false
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
