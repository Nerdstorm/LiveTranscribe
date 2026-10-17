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
/// inference does not occupy the cooperative thread pool. A catalog model that can be told which
/// language to write (Qwen3-ASR, Whisper, Cohere Transcribe) is told the Language setting's at
/// each transcription, so a change applies to the next without loading the model again.
/// Automatic tells it nothing, and it finds the language, except Cohere Transcribe, which can't
/// and is told English. Qwen3-ASR takes the language it's told as no more than a hint, so it's
/// also kept to that language's letters (``ScriptLock``), and decoded here rather than by
/// mlx-audio-swift.
public actor MLXTranscriber: Transcriber {
    /// Shorter clips are returned as empty text rather than sent to the model: they hold no word,
    /// and some models' subsampling (Parakeet's conformer, say) needs a minimum number of frames.
    private static let minimumSamples = AudioFormat.samples(forMilliseconds: 100)

    /// The Speech-to-text setting to load: the one the transcriber was made with, or the last one
    /// it was switched to.
    private var modelID: String
    /// The loaded model, the setting it was loaded for and its folder.
    private var loaded: (modelID: String, model: any STTGenerationModel, folder: URL)?
    /// The masks that lock the loaded Qwen3-ASR's letters to the language it's told, made from
    /// its vocabulary when a language is first told, and the setting they were made for; `nil`
    /// masks if its vocabulary couldn't be read.
    private var lockedLogits: (modelID: String, logits: LockedLogits?)?
    /// A model is taking the place of the one before, which is already gone.
    private var isReplacingModel = false
    /// Transcriptions asked for meanwhile, which wait for the new model.
    private var waitingForModel: [CheckedContinuation<Void, Never>] = []

    private let catalog: SpeechModelCatalog
    private let downloads: SpeechModelDownloads
    /// The Language setting, a code, read at each transcription; `nil` for Automatic.
    private let language: @Sendable () -> String?

    private let queue = DispatchSerialQueue(label: "LiveTranscribe.MLXTranscriber", qos: .userInitiated)
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    public init(
        modelID: String,
        catalog: SpeechModelCatalog = .bundled,
        downloads: SpeechModelDownloads = SpeechModelDownloads(),
        language: @escaping @Sendable () -> String? = { nil }
    ) {
        self.modelID = modelID
        self.catalog = catalog
        self.downloads = downloads
        self.language = language
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
            lockedLogits = nil
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
        loaded = (modelID, model, folder)
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
        guard let loaded else { throw TranscriptionError.modelNotLoaded }
        let model = loaded.model
        guard sampleRate == AudioFormat.sampleRate else {
            throw TranscriptionError.unsupportedSampleRate(sampleRate)
        }
        guard samples.count >= Self.minimumSamples else { return "" }

        let signposter = Log.transcriptionSignposter
        let interval = signposter.beginInterval("STT", id: signposter.makeSignpostID())
        defer { signposter.endInterval("STT", interval) }

        let catalogModel = catalog.model(forSetting: loaded.modelID)
        let setting = language()
        let told = Self.parameters(model.defaultGenerationParameters, for: catalogModel, language: setting)
        let parameters = OutputLimit.capping(told, sampleCount: samples.count)
        let text: String
        let generationTokens: Int
        if let qwen = model as? Qwen3ASRModel, let lock = Self.lock(for: catalogModel, language: setting),
           let logits = lockedLogits(for: loaded) {
            (text, generationTokens) = qwen.generate(audio: MLXArray(samples), parameters: parameters, locking: lock, with: logits)
        } else {
            let output = model.generate(audio: MLXArray(samples), generationParameters: parameters)
            (text, generationTokens) = (output.text, output.generationTokens)
        }
        if parameters.maxTokens > 0, generationTokens >= parameters.maxTokens {
            Log.transcription.warning(
                "STT stopped at its limit of \(parameters.maxTokens, privacy: .public) tokens for \(samples.count / (AudioFormat.sampleRate / 1000), privacy: .public) ms of audio; the model was probably repeating itself"
            )
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The lock on a catalog model's letters for the Language setting: the language's letters,
    /// for a language of the model's that names them (Qwen3-ASR's, ``ScriptLock``). `nil` for
    /// Automatic, which tells Qwen3-ASR nothing, and for a model whose letters aren't locked.
    static func lock(for model: SpeechModelCatalog.Model?, language setting: String?) -> ScriptLock? {
        model?.language(forSetting: setting)?.script.map(ScriptLock.init)
    }

    /// The masks for the loaded model, made from its `vocab.json` the first time a language is
    /// told. If the vocabulary can't be read, the model is told the language unlocked, as
    /// Automatic's would be guessed.
    private func lockedLogits(for loaded: (modelID: String, model: any STTGenerationModel, folder: URL)) -> LockedLogits? {
        if let made = lockedLogits, made.modelID == loaded.modelID { return made.logits }
        var logits: LockedLogits?
        do {
            let json = try Data(contentsOf: loaded.folder.appending(path: "vocab.json"))
            logits = LockedLogits(vocabulary: try LockedVocabulary(vocabularyJSON: json, endOfReply: Qwen3ASRModel.endOfReply))
        } catch {
            Log.transcription.error(
                "STT can't lock its letters to the language it's told, so it's told the language alone: \(String(describing: error), privacy: .public)"
            )
        }
        lockedLogits = (loaded.modelID, logits)
        return logits
    }

    /// `parameters`, with the language to write for a catalog model that can be told one: the
    /// Language setting's if the model has it, and otherwise Automatic's
    /// (``SpeechModelCatalog/Model/language(forSetting:)``). A model that finds the language
    /// itself, and any model outside the catalog, keeps its own parameters, which tell it none.
    static func parameters(
        _ parameters: STTGenerateParameters,
        for model: SpeechModelCatalog.Model?,
        language setting: String?
    ) -> STTGenerateParameters {
        guard let model, let choice = model.language(forSetting: setting) else { return parameters }
        return parameters.replacing(language: model.told(choice))
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
