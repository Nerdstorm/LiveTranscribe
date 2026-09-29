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
    /// Loading the models, or switching the speech model.
    private var loadTask: Task<Void, Never>?
    /// The Speech-to-text setting the transcriber loads: the one at launch, or the latest
    /// ``useSpeechModel(_:)`` named.
    private var speechModel: String
    /// ``useSpeechModel(_:)`` named a model while something used the speech model; it switches
    /// once nothing does.
    private var speechModelPending = false
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
        self.speechModel = settings.sttModel
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
        // Another model was chosen while these loaded.
        await switchSpeechModelIfIdle()?.value
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
        let speechModel = self.speechModel
        speechModelPending = false
        do {
            try await load(model: settings.vadModel) { try await self.dependencies.segmenter.load(progress: progress) }
            try await loadSpeechModel(speechModel, progress: progress)
        } catch let failure as ModelLoadFailure {
            if Task.isCancelled {
                Log.session.notice("Model loading cancelled")
                setPhase(.notLoaded)
            } else {
                setPhase(.failed(.modelLoadFailed(model: failure.model, message: failure.message)))
            }
            return
        } catch {
            setPhase(.failed(.modelLoadFailed(model: speechModel, message: error.localizedDescription)))
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

    // MARK: - Switching the speech model

    /// Loads `modelID`, a Speech-to-text setting, in place of the speech model in use.
    ///
    /// It switches as soon as nothing uses the speech model: at once when the models are ready,
    /// or once the live transcript, or the loading under way, ends. Before the models are first
    /// loaded, ``prepare()`` loads it instead. The phase is ``SessionPhase/loading`` while it
    /// loads, so that neither a live transcript nor dictation starts, and
    /// ``SessionFailure/modelLoadFailed`` if it fails.
    public func useSpeechModel(_ modelID: String) async {
        guard modelID != speechModel else { return }
        speechModel = modelID
        speechModelPending = true
        Log.session.info("Speech model chosen: \(modelID, privacy: .public)")
        await switchSpeechModelIfIdle()?.value
    }

    /// Starts switching the speech model if a new one is waiting and nothing uses the model.
    private func switchSpeechModelIfIdle() -> Task<Void, Never>? {
        guard speechModelPending, loadTask == nil, !isStarting, activeRun == nil else { return nil }
        switch phase {
        case .failed(.modelLoadFailed):
            // Another model may have failed too, so this loads every model that isn't loaded.
            speechModelPending = false
            return Task { await self.prepare() }
        case .ready, .failed:
            let task = Task { await self.switchSpeechModel() }
            loadTask = task
            return task
        case .notLoaded:
            // prepare() loads the model chosen last.
            speechModelPending = false
            return nil
        case .loading, .listening, .stopping:
            return nil
        }
    }

    /// Loads the model chosen last, and again if another is chosen meanwhile.
    private func switchSpeechModel() async {
        defer { loadTask = nil }
        while speechModelPending, !Task.isCancelled {
            speechModelPending = false
            let modelID = speechModel
            setPhase(.loading)
            do {
                try await loadSpeechModel(modelID, progress: progressHandler())
                setPhase(Task.isCancelled ? .notLoaded : .ready)
            } catch let failure as ModelLoadFailure {
                setPhase(Task.isCancelled ? .notLoaded : .failed(.modelLoadFailed(model: failure.model, message: failure.message)))
            } catch {
                setPhase(.failed(.modelLoadFailed(model: modelID, message: error.localizedDescription)))
            }
        }
    }

    /// Loads `modelID` in place of the speech model loaded now, and says which is loaded.
    private func loadSpeechModel(_ modelID: String, progress: @escaping ModelLoadProgressHandler) async throws {
        do {
            try await load(model: modelID) {
                try await self.dependencies.transcriber.switchModel(to: modelID, progress: progress)
            }
            publish(.speechModel(modelID))
        } catch {
            publish(.speechModel(nil))
            throw error
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
        // A model chosen during the session. Not awaited: stop() waits for this method.
        _ = switchSpeechModelIfIdle()
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
