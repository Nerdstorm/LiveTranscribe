import Capture
import Cleanup
import Dictation
import DictationUI
import Foundation
import Hotkey
import Insertion
import MLXSupport
import Permissions
import Persistence
import Segmentation
import Session
import Shared
import Snippets
import Transcription
import TranscriptUI
import Vocabulary

/// The only place concrete implementations are constructed. Everything else depends on protocols.
@MainActor
final class AppComposition {
    let viewModel: TranscriptViewModel
    let dictation: DictationController
    let dictationUI: DictationUIContext
    let hud: DictationHUD
    private let coordinator: SessionCoordinator
    private let store: AppSettingsStore
    private let inputDevices: SystemInputDevices
    private let accessibility: SystemAccessibilityPermission
    private let microphonePermission = SystemMicrophonePermission()
    private var captureNotices = CaptureNoticeFilter()
    private var settingsObserver: NSObjectProtocol?
    private var pendingSettings: Task<Void, Never>?
    private var deviceTask: Task<Void, Never>?

    init() {
        let store = AppSettingsStore()
        store.registerDefaults()
        self.store = store
        let settings = store.load()
        MLXRuntime.configure(gpuCacheLimitMB: settings.gpuCacheLimitMB)

        let applicationSupport = Self.applicationSupport()
        let sessionsDirectory: URL?
        do {
            sessionsDirectory = try SessionStorage.sessionsDirectory(bundleIdentifier: Log.subsystem)
        } catch {
            Log.app.error("Sessions folder unavailable: \(error.localizedDescription, privacy: .public)")
            sessionsDirectory = nil
        }

        let restartPolicy = CaptureRestartPolicy(settings: settings)
        let inputDevices = SystemInputDevices(store: store)
        self.inputDevices = inputDevices
        // One instance of each model, shared by the live transcript and dictation: they never
        // run at once, and the models are loaded only once.
        let transcriber = MLXTranscriber(modelID: settings.sttModel)
        let cleaner = MLXCleaner(configuration: .init(settings: settings))
        let relay = CaptureNoticeRelay()

        coordinator = SessionCoordinator(
            settings: settings,
            dependencies: .init(
                // The microphone choice is read at every Start, so it applies without a relaunch.
                makeAudioSource: {
                    CaptureSessionSource(
                        restartPolicy: restartPolicy,
                        inputDeviceUID: inputDevices.selectedDeviceUID,
                        onNotice: { notice in relay.send(notice, to: .transcript) }
                    )
                },
                segmenter: SileroSegmenter(modelID: settings.vadModel, config: SegmentationConfig(settings: settings)),
                transcriber: transcriber,
                cleaner: cleaner,
                // Read at every Start, like the microphone, so a new level applies without a relaunch.
                cleanupOptions: { CleanupOptions(level: store.load().cleanupLevel) },
                makeSink: { sessionID in
                    guard let sessionsDirectory else {
                        throw PersistenceError.directoryUnavailable("Application Support is not available")
                    }
                    return try JSONLSessionSink(directory: sessionsDirectory, sessionID: sessionID)
                },
                microphonePermission: microphonePermission
            )
        )
        let viewModel = TranscriptViewModel(
            session: coordinator,
            sessionsDirectory: sessionsDirectory,
            inputSelection: inputDevices
        )
        self.viewModel = viewModel

        let snippets = SnippetStore(fileURL: SnippetStore.defaultURL(applicationSupport: applicationSupport, bundleIdentifier: Log.subsystem))
        let vocabulary = VocabularyStore(fileURL: VocabularyStore.defaultURL(applicationSupport: applicationSupport, bundleIdentifier: Log.subsystem))
        let history = JSONLDictationHistory(fileURL: JSONLDictationHistory.defaultURL(applicationSupport: applicationSupport, bundleIdentifier: Log.subsystem))
        let overrides = InserterOverridesStore(fileURL: Self.overridesURL(applicationSupport: applicationSupport))
        accessibility = SystemAccessibilityPermission(pollInterval: .milliseconds(settings.dictation.permissionPollMs))

        let currentSettings: @Sendable () -> AppSettings = { store.load() }
        let dictationSettings = settings.dictation
        // One reader of the focused field: the flow reads the target with it, and the paste
        // reads it again just before ⌘V.
        let focus = SettingsDrivenFocus(settings: currentSettings)
        dictation = DictationController(dependencies: .init(
            hotkeys: CGEventTapHotkeyMonitor(),
            recorder: DictationRecorder(
                makeSource: { deviceUID in
                    CaptureSessionSource(
                        restartPolicy: restartPolicy,
                        inputDeviceUID: deviceUID,
                        onNotice: { notice in relay.send(notice, to: .dictation) }
                    )
                },
                configuration: .init(
                    preRollMs: dictationSettings.preRollMs,
                    maxDurationSeconds: dictationSettings.maxRecordingSeconds,
                    inputDeviceUID: inputDevices.selectedDeviceUID
                )
            ),
            processor: DictationProcessor(transcriber: transcriber, cleaner: cleaner),
            focus: focus,
            delivery: SystemTextDelivery(settings: currentSettings, overrides: overrides, focus: focus),
            history: history,
            snippets: { await Self.load("snippets") { try await snippets.all() } },
            vocabulary: { await Self.load("vocabulary") { try await vocabulary.all() } },
            settings: currentSettings,
            readiness: { await MainActor.run { DictationReadiness(sessionPhase: viewModel.phase) } },
            microphonePermission: microphonePermission,
            accessibility: accessibility,
            now: { ContinuousClock.now },
            // A new choice reopens the microphone when it is kept ready (applySettings).
            inputDeviceUID: { inputDevices.selectedDeviceUID }
        ))
        dictationUI = DictationUIContext(
            controller: dictation,
            transcript: viewModel,
            settingsStore: store,
            snippets: snippets,
            vocabulary: vocabulary,
            overrides: overrides,
            history: history,
            microphonePermission: microphonePermission,
            accessibility: accessibility
        )
        hud = DictationHUD(controller: dictation)
        relay.deliver = { [weak self] notice, destination in self?.show(notice, in: destination) }

        Log.app.info(
            "Composed: stt=\(settings.sttModel, privacy: .public) llm=\(settings.llmModel, privacy: .public) cleanup=\(settings.cleanupEnabled) dictation=\(settings.dictation.enabled)"
        )
    }

    /// Loads the models and starts the dictation hotkey. Settings changed anywhere (the
    /// Settings window, the menu) are applied to dictation as they happen.
    func start() {
        viewModel.attach()
        dictation.start()
        settingsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsChanged() }
        }
        let changes = inputDevices.changes()
        deviceTask = Task { [weak self] in
            for await _ in changes {
                self?.captureNotices.devicesChanged()
            }
        }
    }

    /// Whether first-launch setup is still needed: dictation cannot work without both permissions.
    var needsOnboarding: Bool {
        store.load().dictation.enabled
            && (microphonePermission.status() != .granted || !accessibility.isGranted())
    }

    /// Applies settings once a burst of changes (a stepper held down, several keys saved at
    /// once) has settled.
    private func settingsChanged() {
        pendingSettings?.cancel()
        let delay = store.load().dictation.settingsApplyDelayMs
        pendingSettings = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(delay))
            guard !Task.isCancelled else { return }
            self?.dictation.applySettings()
        }
    }

    func shutdown() async {
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
        pendingSettings?.cancel()
        deviceTask?.cancel()
        dictation.stop()
        await coordinator.shutdown()
    }

    private func show(_ notice: CaptureNotice, in destination: CaptureNoticeRelay.Destination) {
        switch destination {
        case .transcript:
            viewModel.showCaptureNotice(notice.message)
        case .dictation:
            guard captureNotices.shouldShow(notice) else { return }
            dictation.showMicrophoneNotice(notice.message)
        }
    }

    // MARK: - Files

    private static func applicationSupport() -> URL {
        do {
            return try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        } catch {
            Log.app.error("Application Support unavailable, using a temporary folder: \(error.localizedDescription, privacy: .public)")
            return FileManager.default.temporaryDirectory
        }
    }

    private static func overridesURL(applicationSupport: URL) -> URL {
        do {
            return try InserterOverridesStore.defaultFileURL(bundleIdentifier: Log.subsystem)
        } catch {
            Log.app.error("Insertion overrides folder unavailable: \(error.localizedDescription, privacy: .public)")
            return applicationSupport.appending(path: Log.subsystem).appending(path: InserterOverridesStore.fileName)
        }
    }

    /// A dictation goes ahead without snippets or vocabulary rather than failing when one of
    /// the files cannot be read; Settings shows the error.
    private nonisolated static func load<Item: Sendable>(_ name: String, _ read: () async throws -> [Item]) async -> [Item] {
        do {
            return try await read()
        } catch {
            Log.dictation.error("Dictation continues without \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return []
        }
    }
}

/// Carries microphone notices from capture's queue to the main actor.
@MainActor
private final class CaptureNoticeRelay {
    enum Destination: Sendable { case transcript, dictation }

    /// Set once, before any capture starts.
    var deliver: ((CaptureNotice, Destination) -> Void)?

    nonisolated func send(_ notice: CaptureNotice, to destination: Destination) {
        Task { @MainActor in self.deliver?(notice, destination) }
    }
}

/// The focused field, read with the Accessibility timeout current in Settings.
private struct SettingsDrivenFocus: FocusedTargetProvider {
    let settings: @Sendable () -> AppSettings

    func currentTarget() -> InsertionTarget {
        SystemFocusedTargetProvider(messagingTimeoutMs: settings().dictation.accessibilityTimeoutMs).currentTarget()
    }
}
