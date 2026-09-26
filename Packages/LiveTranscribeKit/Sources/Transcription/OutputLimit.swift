import MLXAudioSTT
import Shared

/// How long a transcript may run, set by the length of its audio.
///
/// A speech-to-text model that falls into repeating a phrase carries on to its own limit: 8,192
/// tokens for Qwen3-ASR, about a minute of decoding, and all of it typed. mlx-audio-swift stops a
/// loop only when its last 24 tokens hold 3 or fewer different tokens, and a Sinhala word is often
/// 8 tokens or more, as is a short English phrase. Speech takes about 3.6 tokens a second in
/// English and 8.2 in Sinhala, so 64 tokens plus 30 a second leaves real speech room to spare and
/// stops a loop within the length of its clip.
public enum OutputLimit {
    static let baseTokens = 64
    static let tokensPerSecond = 30

    /// The most tokens a transcript of `sampleCount` samples of 16 kHz audio may take.
    public static func maxTokens(forSampleCount sampleCount: Int) -> Int {
        let seconds = Double(sampleCount) / Double(AudioFormat.sampleRate)
        return baseTokens + Int((seconds * Double(tokensPerSecond)).rounded(.up))
    }

    /// `parameters` with `maxTokens` lowered to the limit for `sampleCount` samples. The limit only
    /// ever lowers: a model whose own limit is already lower keeps it, and so does one that doesn't
    /// count tokens this way (the CTC models' 0).
    public static func capping(_ parameters: STTGenerateParameters, sampleCount: Int) -> STTGenerateParameters {
        let limit = maxTokens(forSampleCount: sampleCount)
        guard parameters.maxTokens > limit else { return parameters }
        return STTGenerateParameters(
            maxTokens: limit,
            temperature: parameters.temperature,
            topP: parameters.topP,
            topK: parameters.topK,
            verbose: parameters.verbose,
            language: parameters.language,
            chunkDuration: parameters.chunkDuration,
            minChunkDuration: parameters.minChunkDuration,
            repetitionPenalty: parameters.repetitionPenalty,
            repetitionContextSize: parameters.repetitionContextSize,
            kvBits: parameters.kvBits,
            kvGroupSize: parameters.kvGroupSize,
            quantizedKVStart: parameters.quantizedKVStart
        )
    }
}
