import Foundation
import HuggingFace
@preconcurrency import MLX
import MLXAudioCore
import MLXAudioSTT
import Shared

/// ``Transcriber`` backed by an mlx-audio-swift STT model (Qwen3-ASR by default): any kind in
/// ``SpeechModelKind``, from a Hugging Face repository or a folder (``SpeechModelLocation``). A
/// repository in the ``SpeechModelCatalog`` is downloaded at its pinned commit
/// (``SpeechModelDownloads``); any other repository at its latest, by mlx-audio-swift.
///
/// The model is loaded once and warmed up, and replaced when ``switchModel(to:progress:)`` names
/// another. It never leaves this actor, which runs on its own serial queue so the blocking MLX
/// inference does not occupy the cooperative thread pool.
public actor MLXTranscriber: Transcriber {
    /// Shorter clips are returned as empty text rather than sent to the model: they hold no word,
    /// and some models' subsampling (Parakeet's conformer, say) needs a minimum number of frames.
    private static let minimumSamples = AudioFormat.samples(forMilliseconds: 100)

    /// The Speech-to-text setting to load: the one the transcriber was made with, or the last one
    /// it was switched to.
    private var modelID: String
    /// The loaded model, and the setting it was loaded for.
    private var loaded: (modelID: String, model: any STTGenerationModel)?
    /// A model is taking the place of the one before, which is already gone.
    private var isReplacingModel = false
    /// Transcriptions asked for meanwhile, which wait for the new model.
    private var waitingForModel: [CheckedContinuation<Void, Never>] = []

    private let catalog: SpeechModelCatalog
    private let downloads: SpeechModelDownloads

    private let queue = DispatchSerialQueue(label: "LiveTranscribe.MLXTranscriber", qos: .userInitiated)
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    public init(modelID: String, catalog: SpeechModelCatalog = .bundled, downloads: SpeechModelDownloads = SpeechModelDownloads()) {
        self.modelID = modelID
        self.catalog = catalog
        self.downloads = downloads
    }

    /// Loads the model the setting names, unless it's loaded already.
    ///
    /// Downloading comes first, while the model loaded before (if any) keeps transcribing. Then
    /// that model goes, so that two are never in memory together, and the new one loads.
    public func load(progress: @escaping ModelLoadProgressHandler) async throws {
        let modelID = self.modelID
        guard loaded?.modelID != modelID else { return }
        let location = try SpeechModelLocation(setting: modelID)
        let folder = try await folder(for: location, progress: progress)
        try Task.checkCancellation()

        progress(ModelLoadProgress(modelID: modelID, stage: .loading))
        let kind = try SpeechModelKind.of(folder: folder, name: location.name)
        isReplacingModel = true
        defer { finishReplacingModel() }
        if loaded != nil {
            loaded = nil
            Memory.clearCache()
        }
        let model = try await kind.load(folder)

        // The first call compiles Metal kernels; pay that now, not on the first utterance.
        progress(ModelLoadProgress(modelID: modelID, stage: .warmingUp))
        let started = ContinuousClock.now
        _ = model.generate(
            audio: MLXArray.zeros([AudioFormat.sampleRate]),
            generationParameters: OutputLimit.capping(model.defaultGenerationParameters, sampleCount: AudioFormat.sampleRate)
        )
        loaded = (modelID, model)
        progress(ModelLoadProgress(modelID: modelID, stage: .ready, fractionCompleted: 1))
        Log.transcription.info(
            "STT model ready: \(location.description, privacy: .public), \(kind.modelType, privacy: .public) (warm-up \(started.duration(to: .now).wholeMilliseconds) ms)"
        )
    }

    public func switchModel(to modelID: String, progress: @escaping ModelLoadProgressHandler) async throws {
        self.modelID = modelID
        try await load(progress: progress)
    }

    public func transcribe(_ samples: [Float], sampleRate: Int) async throws -> String {
        if isReplacingModel {
            await withCheckedContinuation { waitingForModel.append($0) }
        }
        guard let model = loaded?.model else { throw TranscriptionError.modelNotLoaded }
        guard sampleRate == AudioFormat.sampleRate else {
            throw TranscriptionError.unsupportedSampleRate(sampleRate)
        }
        guard samples.count >= Self.minimumSamples else { return "" }

        let signposter = Log.transcriptionSignposter
        let interval = signposter.beginInterval("STT", id: signposter.makeSignpostID())
        defer { signposter.endInterval("STT", interval) }

        let parameters = OutputLimit.capping(model.defaultGenerationParameters, sampleCount: samples.count)
        let output = model.generate(audio: MLXArray(samples), generationParameters: parameters)
        if parameters.maxTokens > 0, output.generationTokens >= parameters.maxTokens {
            Log.transcription.warning(
                "STT stopped at its limit of \(parameters.maxTokens, privacy: .public) tokens for \(samples.count / (AudioFormat.sampleRate / 1000), privacy: .public) ms of audio; the model was probably repeating itself"
            )
        }
        return output.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The model's folder, downloaded first when it's a repository.
    private func folder(for location: SpeechModelLocation, progress: @escaping ModelLoadProgressHandler) async throws -> URL {
        let modelID = self.modelID
        let downloading: @MainActor @Sendable (Double) -> Void = { fraction in
            progress(ModelLoadProgress(modelID: modelID, stage: .downloading, fractionCompleted: fraction))
        }
        switch location {
        case .folder(let url):
            return url
        case .repository(let repoID):
            if let model = catalog.model(forSetting: repoID.rawValue) {
                if let folder = downloads.folder(for: model) { return folder }
                progress(ModelLoadProgress(modelID: modelID, stage: .downloading, fractionCompleted: 0))
                do {
                    return try await downloads.download(model, progress: downloading)
                } catch where !(error is CancellationError) {
                    // Offline after an update, say: the copy an earlier version downloaded still works.
                    guard let olderCopy = downloads.olderCopy(of: model) else { throw error }
                    Log.transcription.notice(
                        "Loading the older download of \(repoID.rawValue, privacy: .public): its pinned commit couldn't be downloaded (\(error.localizedDescription, privacy: .public))"
                    )
                    return olderCopy
                }
            }
            // Any other repository: mlx-audio-swift's folder for it, downloaded at its latest.
            progress(ModelLoadProgress(modelID: modelID, stage: .downloading, fractionCompleted: 0))
            return try await ModelUtils.resolveOrDownloadModel(
                client: HubClient(cache: .default),
                cache: .default,
                repoID: repoID,
                requiredExtension: "safetensors",
                additionalMatchingPatterns: SpeechModelKind.downloadPatterns,
                progressHandler: { fileProgress in downloading(fileProgress.fractionCompleted) }
            )
        }
    }

    private func finishReplacingModel() {
        isReplacingModel = false
        let waiting = waitingForModel
        waitingForModel = []
        waiting.forEach { $0.resume() }
    }
}
