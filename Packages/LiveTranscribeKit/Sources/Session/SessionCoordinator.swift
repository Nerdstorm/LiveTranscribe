import Capture
import Cleanup
import Foundation
import Persistence
import Segmentation
import Shared
import Transcription

/// Owns the session lifecycle: loads models, checks microphone permission, starts and stops
/// listening, and publishes ``SessionEvent``s for the UI.
///
/// Depends only on the slice protocols; concrete implementations are injected.
public actor SessionCoordinator: SessionControlling {
    public struct Dependencies: Sendable {
        public var makeAudioSource: @Sendable () -> any AudioSource
        public var segmenter: any SpeechSegmenter
        public var transcriber: any Transcriber
        public var cleaner: any Cleaner
        /// Read at every Start, so a change of cleanup level applies to the next session.
        public var cleanupOptions: @Sendable () -> CleanupOptions
        public var makeSink: @Sendable (UUID) async throws -> any SessionSink
        public var microphonePermission: any MicrophonePermissionProviding

        public init(
            makeAudioSource: @escaping @Sendable () -> any AudioSource,
            segmenter: any SpeechSegmenter,
            transcriber: any Transcriber,
            cleaner: any Cleaner,
            cleanupOptions: @escaping @Sendable () -> CleanupOptions,
            makeSink: @escaping @Sendable (UUID) async throws -> any SessionSink,
            microphonePermission: any MicrophonePermissionProviding
        ) {
            self.makeAudioSource = makeAudioSource
            self.segmenter = segmenter
            self.transcriber = transcriber
            self.cleaner = cleaner
            self.cleanupOptions = cleanupOptions
            self.makeSink = makeSink
            self.microphonePermission = microphonePermission
        }
    }

    private struct ActiveRun {
        let source: any AudioSource
        let sink: any SessionSink
        let task: Task<Void, Never>
    }

    public nonisolated let events: AsyncStream<SessionEvent>
    private nonisolated let eventInput: AsyncStream<SessionEvent>.Continuation

    private let settings: AppSettings
    private let dependencies: Dependencies
    private var phase: SessionPhase = .notLoaded
    private var cleanupAvailability: CleanupAvailability
    private var loadTask: Task<Void, Never>?
    private var activeRun: ActiveRun?
    /// A ``start()`` is under way: it awaits permission, the session file and the microphone
    /// before `activeRun` is set, so without this a second Start would open a second capture
    /// that nothing tracks or stops.
    private var isStarting = false

    public init(settings: AppSettings, dependencies: Dependencies) {
        (events, eventInput) = AsyncStream.makeStream(of: SessionEvent.self)
        self.settings = settings
        self.dependencies = dependencies
        self.cleanupAvailability = settings.cleanupEnabled ? .pending : .disabled
    }

    // MARK: - Model loading

    public func prepare() async {
        switch phase {
        case .notLoaded, .failed(.modelLoadFailed): break
        default: return
        }
        setPhase(.loading)
        publish(.cleanupAvailability(cleanupAvailability))
        let task = Task { await self.loadModels() }
        loadTask = task
        await task.value
        loadTask = nil
    }

    public func cancelPreparation() {
        loadTask?.cancel()
    }

    public func retryCleanup() async {
        guard case .unavailable = cleanupAvailability, phase == .ready else { return }
        await loadCleaner()
    }

    private func loadModels() async {
        let progress = progressHandler()
        do {
            try await load(model: settings.vadModel) { try await self.dependencies.segmenter.load(progress: progress) }
            try await load(model: settings.sttModel) { try await self.dependencies.transcriber.load(progress: progress) }
        } catch let failure as ModelLoadFailure {
            if Task.isCancelled {
                Log.session.notice("Model loading cancelled")
                setPhase(.notLoaded)
            } else {
                setPhase(.failed(.modelLoadFailed(model: failure.model, message: failure.message)))
            }
            return
        } catch {
            setPhase(.failed(.modelLoadFailed(model: settings.sttModel, message: error.localizedDescription)))
            return
        }

        if settings.cleanupEnabled {
            await loadCleaner()
        }
        setPhase(Task.isCancelled ? .notLoaded : .ready)
    }

    /// Cleanup failing to load is not fatal: the session continues raw-only.
    private func loadCleaner() async {
        setCleanupAvailability(.pending)
        do {
            try await load(model: settings.llmModel) { try await self.dependencies.cleaner.load(progress: self.progressHandler()) }
            setCleanupAvailability(.available)
        } catch let failure as ModelLoadFailure {
            setCleanupAvailability(.unavailable(model: failure.model, message: failure.message))
        } catch {
            setCleanupAvailability(.unavailable(model: settings.llmModel, message: error.localizedDescription))
        }
    }

    private func load(model: String, _ operation: () async throws -> Void) async throws {
        do {
            try await operation()
        } catch {
            Log.session.error("Loading \(model, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            throw ModelLoadFailure(model: model, message: error.localizedDescription)
        }
    }

    private nonisolated func progressHandler() -> ModelLoadProgressHandler {
        let input = eventInput
        return { input.yield(.modelProgress($0)) }
    }

    // MARK: - Listening

    public func start() async {
        switch phase {
        case .ready, .failed(.microphonePermissionDenied), .failed(.audioCaptureFailed), .failed(.persistenceFailed):
            break
        default:
            return
        }
        guard !isStarting, activeRun == nil else { return }
        isStarting = true
        defer { isStarting = false }
        guard await dependencies.microphonePermission.request() else {
            Log.session.notice("Microphone permission denied")
            setPhase(.failed(.microphonePermissionDenied))
            return
        }

        let sessionID = UUID()
        let sink: any SessionSink
        do {
            sink = try await dependencies.makeSink(sessionID)
        } catch {
            setPhase(.failed(.persistenceFailed(message: error.localizedDescription)))
            return
        }

        await dependencies.segmenter.reset()
        let source = dependencies.makeAudioSource()
        let audio: AsyncThrowingStream<[Float], Error>
        do {
            audio = try await source.start()
        } catch {
            try? await sink.close()
            setPhase(.failed(.audioCaptureFailed(message: error.localizedDescription)))
            return
        }

        let pipeline = SessionPipeline(
            configuration: .init(
                sessionID: sessionID,
                contextSegments: settings.contextSegments,
                cleanupQueueCapacity: settings.cleanupQueueCapacity,
                cleanupOptions: dependencies.cleanupOptions()
            ),
            segmenter: dependencies.segmenter,
            transcriber: dependencies.transcriber,
            cleaner: cleanupAvailability == .available ? dependencies.cleaner : nil,
            sink: sink,
            emit: { [eventInput] in eventInput.yield($0) }
        )
        let task = Task {
            let failure = await pipeline.run(audio: audio)
            await self.pipelineFinished(failure: failure)
        }
        activeRun = ActiveRun(source: source, sink: sink, task: task)
        publish(.sessionStarted(sessionID: sessionID, transcriptFile: sink.location))
        setPhase(.listening)
        Log.session.info("Session \(sessionID.uuidString, privacy: .public) started")
    }

    public func stop() async {
        guard phase == .listening, let run = activeRun else { return }
        setPhase(.stopping)
        // Release the microphone first; the pipeline then drains what it already has.
        await run.source.stop()
        await run.task.value
    }

    public func shutdown() async {
        loadTask?.cancel()
        if phase == .listening {
            await stop()
        } else if let run = activeRun {
            await run.task.value
        }
        eventInput.finish()
    }

    private func pipelineFinished(failure: Error?) async {
        guard let run = activeRun else { return }
        await run.source.stop()
        do {
            try await run.sink.close()
        } catch {
            Log.persistence.error("Closing the session file failed: \(error.localizedDescription, privacy: .public)")
            publish(.warning("The session file could not be closed cleanly: \(error.localizedDescription)"))
        }
        activeRun = nil
        if let failure {
            setPhase(.failed(.audioCaptureFailed(message: failure.localizedDescription)))
        } else {
            setPhase(.ready)
        }
        Log.session.info("Session finished")
    }

    // MARK: - State publishing

    private func setPhase(_ newPhase: SessionPhase) {
        guard newPhase != phase else { return }
        phase = newPhase
        publish(.phase(newPhase))
    }

    private func setCleanupAvailability(_ availability: CleanupAvailability) {
        guard availability != cleanupAvailability else { return }
        cleanupAvailability = availability
        publish(.cleanupAvailability(availability))
    }

    private func publish(_ event: SessionEvent) {
        eventInput.yield(event)
    }
}

private struct ModelLoadFailure: Error {
    let model: String
    let message: String
}
