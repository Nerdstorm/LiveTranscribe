import Capture
import Foundation
import Hotkey
import Insertion
import Permissions
import Persistence
import Shared
import Snippets
import Vocabulary

extension DictationController {
    /// Everything the controller drives, injected so the flow can be tested with fakes.
    public struct Dependencies: Sendable {
        public var hotkeys: any HotkeyMonitor
        public var recorder: DictationRecorder
        public var processor: DictationProcessor
        public var focus: any FocusedTargetProvider
        public var delivery: any TextDelivery
        public var history: any DictationHistory
        public var snippets: @Sendable () async -> [Snippet]
        public var vocabulary: @Sendable () async -> [VocabularyEntry]
        public var settings: @Sendable () -> AppSettings
        public var readiness: @Sendable () async -> DictationReadiness
        public var microphonePermission: any MicrophonePermissionProviding
        public var accessibility: any AccessibilityPermissionProviding
        public var now: @Sendable () -> ContinuousClock.Instant
        /// The microphone chosen in Settings, `nil` for the system default.
        public var inputDeviceUID: @Sendable () -> String?
        /// Waits between the periodic history prunes: `Task.sleep` in the app. It throws when
        /// the waiting task is cancelled. Tests pass one they end by hand.
        public var sleep: @Sendable (Duration) async throws -> Void

        public init(
            hotkeys: any HotkeyMonitor,
            recorder: DictationRecorder,
            processor: DictationProcessor,
            focus: any FocusedTargetProvider,
            delivery: any TextDelivery,
            history: any DictationHistory,
            snippets: @escaping @Sendable () async -> [Snippet],
            vocabulary: @escaping @Sendable () async -> [VocabularyEntry],
            settings: @escaping @Sendable () -> AppSettings,
            readiness: @escaping @Sendable () async -> DictationReadiness,
            microphonePermission: any MicrophonePermissionProviding,
            accessibility: any AccessibilityPermissionProviding,
            now: @escaping @Sendable () -> ContinuousClock.Instant,
            inputDeviceUID: @escaping @Sendable () -> String? = { nil },
            sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
        ) {
            self.hotkeys = hotkeys
            self.recorder = recorder
            self.processor = processor
            self.focus = focus
            self.delivery = delivery
            self.history = history
            self.snippets = snippets
            self.vocabulary = vocabulary
            self.settings = settings
            self.readiness = readiness
            self.microphonePermission = microphonePermission
            self.accessibility = accessibility
            self.now = now
            self.inputDeviceUID = inputDeviceUID
            self.sleep = sleep
        }
    }
}
