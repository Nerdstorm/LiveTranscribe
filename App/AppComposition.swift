import Capture
import Cleanup
import Foundation
import MLXSupport
import Persistence
import Segmentation
import Session
import Shared
import Transcription
import TranscriptUI

/// The only place concrete implementations are constructed. Everything else depends on protocols.
@MainActor
final class AppComposition {
    let viewModel: TranscriptViewModel
    private let coordinator: SessionCoordinator

    init() {
        let store = AppSettingsStore()
        store.registerDefaults()
        let settings = store.load()
        MLXRuntime.configure(gpuCacheLimitMB: settings.gpuCacheLimitMB)

        let sessionsDirectory: URL?
        do {
            sessionsDirectory = try SessionStorage.sessionsDirectory(bundleIdentifier: Log.subsystem)
        } catch {
            Log.app.error("Sessions folder unavailable: \(error.localizedDescription, privacy: .public)")
            sessionsDirectory = nil
        }

        let restartPolicy = CaptureRestartPolicy(settings: settings)
        let inputDevices = SystemInputDevices(store: store)
        coordinator = SessionCoordinator(
            settings: settings,
            dependencies: .init(
                // The microphone choice is read at every Start, so it applies without a relaunch.
                makeAudioSource: {
                    CaptureSessionSource(restartPolicy: restartPolicy, inputDeviceUID: inputDevices.selectedDeviceUID)
                },
                segmenter: SileroSegmenter(modelID: settings.vadModel, config: SegmentationConfig(settings: settings)),
                transcriber: MLXTranscriber(modelID: settings.sttModel),
                cleaner: MLXCleaner(configuration: .init(settings: settings)),
                // Read at every Start, like the microphone, so a new level applies without a relaunch.
                cleanupOptions: { CleanupOptions(level: store.load().cleanupLevel) },
                makeSink: { sessionID in
                    guard let sessionsDirectory else {
                        throw PersistenceError.directoryUnavailable("Application Support is not available")
                    }
                    return try JSONLSessionSink(directory: sessionsDirectory, sessionID: sessionID)
                },
                microphonePermission: SystemMicrophonePermission()
            )
        )
        viewModel = TranscriptViewModel(
            session: coordinator,
            sessionsDirectory: sessionsDirectory,
            inputSelection: inputDevices
        )
        Log.app.info(
            "Composed: stt=\(settings.sttModel, privacy: .public) llm=\(settings.llmModel, privacy: .public) cleanup=\(settings.cleanupEnabled)"
        )
    }

    func shutdown() async {
        await coordinator.shutdown()
    }
}
