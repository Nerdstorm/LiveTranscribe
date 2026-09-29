import MLXAudioSTT

extension STTGenerateParameters {
    /// These parameters with `maxTokens` or `language` replaced, and every other value kept:
    /// mlx-audio-swift's parameters are constants.
    func replacing(maxTokens: Int? = nil, language: String? = nil) -> STTGenerateParameters {
        STTGenerateParameters(
            maxTokens: maxTokens ?? self.maxTokens,
            temperature: temperature,
            topP: topP,
            topK: topK,
            verbose: verbose,
            language: language ?? self.language,
            chunkDuration: chunkDuration,
            minChunkDuration: minChunkDuration,
            repetitionPenalty: repetitionPenalty,
            repetitionContextSize: repetitionContextSize,
            kvBits: kvBits,
            kvGroupSize: kvGroupSize,
            quantizedKVStart: quantizedKVStart
        )
    }
}
