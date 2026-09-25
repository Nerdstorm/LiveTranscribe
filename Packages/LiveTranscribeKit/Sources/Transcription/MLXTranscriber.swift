import Foundation
import HuggingFace
@preconcurrency import MLX
import MLXAudioCore
import MLXAudioSTT
import Shared

/// ``Transcriber`` backed by an mlx-audio-swift STT model (Qwen3-ASR by default).
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
        guard let repoID = Repo.ID(rawValue: modelID) else {
            throw TranscriptionError.invalidModelID(modelID)
        }

        // Download first, with progress; STT.loadModel then finds the files in the cache.
        progress(ModelLoadProgress(modelID: modelID, stage: .downloading, fractionCompleted: 0))
        _ = try await ModelUtils.resolveOrDownloadModel(
            client: HubClient(cache: .default),
            cache: .default,
            repoID: repoID,
            requiredExtension: "safetensors",
            progressHandler: { fileProgress in
                progress(ModelLoadProgress(
                    modelID: modelID,
                    stage: .downloading,
                    fractionCompleted: fileProgress.fractionCompleted
                ))
            }
        )
        try Task.checkCancellation()

        progress(ModelLoadProgress(modelID: modelID, stage: .loading))
        let loaded = try await STT.loadModel(modelRepo: modelID)

        // The first call compiles Metal kernels; pay that now, not on the first utterance.
        progress(ModelLoadProgress(modelID: modelID, stage: .warmingUp))
        let started = ContinuousClock.now
        _ = loaded.generate(audio: MLXArray.zeros([AudioFormat.sampleRate]))
        model = loaded
        progress(ModelLoadProgress(modelID: modelID, stage: .ready, fractionCompleted: 1))
        Log.transcription.info(
            "STT model ready: \(modelID, privacy: .public) (warm-up \(started.duration(to: .now).wholeMilliseconds) ms)"
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

        let output = model.generate(audio: MLXArray(samples))
        return output.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
