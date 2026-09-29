import Foundation
import HuggingFace
@preconcurrency import MLX
import MLXAudioCore
import MLXAudioSTT
import Shared

/// ``Transcriber`` backed by an mlx-audio-swift STT model (Qwen3-ASR by default): any kind in
/// ``SpeechModelKind``, from a Hugging Face repository or a folder (``SpeechModelLocation``).
///
/// The model is loaded once and warmed up. It never leaves this actor, which runs on its own
/// serial queue so the blocking MLX inference does not occupy the cooperative thread pool.
public actor MLXTranscriber: Transcriber {
    /// Shorter clips are returned as empty text rather than sent to the model: they hold no word,
    /// and some models' subsampling (Parakeet's conformer, say) needs a minimum number of frames.
    private static let minimumSamples = AudioFormat.samples(forMilliseconds: 100)

    private let modelID: String
    private var model: (any STTGenerationModel)?

    private let queue = DispatchSerialQueue(label: "LiveTranscribe.MLXTranscriber", qos: .userInitiated)
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    public init(modelID: String) {
        self.modelID = modelID
    }

    public func load(progress: @escaping ModelLoadProgressHandler) async throws {
        guard model == nil else { return }
        let modelID = self.modelID
        let location = try SpeechModelLocation(setting: modelID)

        let folder: URL
        switch location {
        case .repository(let repoID):
            // Download first, with progress, into mlx-audio-swift's folder for the repository.
            progress(ModelLoadProgress(modelID: modelID, stage: .downloading, fractionCompleted: 0))
            folder = try await ModelUtils.resolveOrDownloadModel(
                client: HubClient(cache: .default),
                cache: .default,
                repoID: repoID,
                requiredExtension: "safetensors",
                additionalMatchingPatterns: SpeechModelKind.downloadPatterns,
                progressHandler: { fileProgress in
                    progress(ModelLoadProgress(
                        modelID: modelID,
                        stage: .downloading,
                        fractionCompleted: fileProgress.fractionCompleted
                    ))
                }
            )
            try Task.checkCancellation()
        case .folder(let url):
            folder = url
        }

        progress(ModelLoadProgress(modelID: modelID, stage: .loading))
        let kind = try SpeechModelKind.of(folder: folder, name: location.name)
        let loaded = try await kind.load(folder)

        // The first call compiles Metal kernels; pay that now, not on the first utterance.
        progress(ModelLoadProgress(modelID: modelID, stage: .warmingUp))
        let started = ContinuousClock.now
        _ = loaded.generate(
            audio: MLXArray.zeros([AudioFormat.sampleRate]),
            generationParameters: OutputLimit.capping(loaded.defaultGenerationParameters, sampleCount: AudioFormat.sampleRate)
        )
        model = loaded
        progress(ModelLoadProgress(modelID: modelID, stage: .ready, fractionCompleted: 1))
        Log.transcription.info(
            "STT model ready: \(location.description, privacy: .public), \(kind.modelType, privacy: .public) (warm-up \(started.duration(to: .now).wholeMilliseconds) ms)"
        )
    }

    public func transcribe(_ samples: [Float], sampleRate: Int) throws -> String {
        guard let model else { throw TranscriptionError.modelNotLoaded }
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
}
