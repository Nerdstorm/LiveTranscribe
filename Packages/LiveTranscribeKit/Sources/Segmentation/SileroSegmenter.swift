import Foundation
@preconcurrency import MLX
import MLXAudioVAD
import Shared

/// ``SpeechSegmenter`` backed by Silero VAD (mlx-audio-swift), run in streaming mode.
///
/// The MLX model and its recurrent state never leave this actor. The actor runs on its own
/// serial queue so the (blocking) MLX evaluation does not occupy the cooperative thread pool.
public actor SileroSegmenter: SpeechSegmenter {
    /// Silero's fixed analysis window at 16 kHz (32 ms).
    public static let chunkSize = 512

    private let modelID: String
    private let config: SegmentationConfig
    private var model: SileroVAD?
    private var streamingState: SileroVADStreamingState?
    private var accumulator = ChunkAccumulator(chunkSize: SileroSegmenter.chunkSize)
    private var machine: SegmentationStateMachine

    private let queue = DispatchSerialQueue(label: "LiveTranscribe.SileroSegmenter", qos: .userInitiated)
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    public init(modelID: String, config: SegmentationConfig) {
        self.modelID = modelID
        self.config = config
        self.machine = SegmentationStateMachine(config: config)
    }

    public func load(progress: @escaping ModelLoadProgressHandler) async throws {
        guard model == nil else { return }
        progress(ModelLoadProgress(modelID: modelID, stage: .loading))
        let loaded = try await SileroVAD.fromPretrained(modelID)
        model = loaded
        progress(ModelLoadProgress(modelID: modelID, stage: .ready, fractionCompleted: 1))
        Log.segmentation.info("VAD model loaded: \(self.modelID, privacy: .public)")
    }

    public func reset() {
        streamingState = nil
        accumulator.reset()
        machine = SegmentationStateMachine(config: config)
    }

    public func process(_ samples: [Float]) throws -> [SegmentationEvent] {
        guard let model else { throw SegmentationError.modelNotLoaded }
        var events: [SegmentationEvent] = []
        for chunk in accumulator.append(samples) {
            let probability = try speechProbability(of: chunk, model: model)
            events.append(contentsOf: machine.ingest(chunk: chunk, speechProbability: probability))
        }
        return events
    }

    public func flush() -> [SegmentationEvent] {
        accumulator.reset()
        return machine.flush()
    }

    private func speechProbability(of chunk: [Float], model: SileroVAD) throws -> Float {
        let (probability, state) = try model.feed(
            chunk: MLXArray(chunk),
            state: streamingState,
            sampleRate: AudioFormat.sampleRate
        )
        // Evaluate the recurrent state with the output so the lazy graph never grows across chunks.
        var arrays = [probability, state.context]
        if let lstmState = state.lstmState {
            arrays.append(lstmState)
        }
        eval(arrays)
        streamingState = state
        return probability.item(Float.self)
    }
}
