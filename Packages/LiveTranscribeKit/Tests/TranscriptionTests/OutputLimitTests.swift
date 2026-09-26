import MLXAudioSTT
import Shared
import Testing
import Transcription

struct OutputLimitTests {
    @Test func allowsSixtyFourTokensAndThirtyASecond() {
        #expect(OutputLimit.maxTokens(forSampleCount: 0) == 64)
        #expect(OutputLimit.maxTokens(forSampleCount: AudioFormat.sampleRate) == 94)
        #expect(OutputLimit.maxTokens(forSampleCount: 30 * AudioFormat.sampleRate) == 964)
        // Part of a second rounds up: 8.88 s is 266.4 tokens' worth.
        #expect(OutputLimit.maxTokens(forSampleCount: 142_080) == 331)
    }

    @Test func lowersTheModelsOwnLimit() {
        let qwen = STTGenerateParameters(maxTokens: 8192)
        #expect(OutputLimit.capping(qwen, sampleCount: 142_080).maxTokens == 331)
    }

    @Test func neverRaisesALimit() {
        // Moonshine's and Canary's 200 is already under 10 s's 364.
        let short = STTGenerateParameters(maxTokens: 200)
        #expect(OutputLimit.capping(short, sampleCount: 10 * AudioFormat.sampleRate).maxTokens == 200)
        // The CTC models don't count tokens, and 0 must stay 0.
        let ctc = STTGenerateParameters(maxTokens: 0)
        #expect(OutputLimit.capping(ctc, sampleCount: 10 * AudioFormat.sampleRate).maxTokens == 0)
    }

    @Test func keepsEverythingElse() {
        let parameters = STTGenerateParameters(
            maxTokens: 8192, temperature: 0.2, topP: 0.9, topK: 5, verbose: true, language: "Sinhala",
            chunkDuration: 30, minChunkDuration: 2, repetitionPenalty: 1.1, repetitionContextSize: 16,
            kvBits: 8, kvGroupSize: 32, quantizedKVStart: 4
        )
        let capped = OutputLimit.capping(parameters, sampleCount: AudioFormat.sampleRate)
        #expect(capped.maxTokens == 94)
        #expect(capped.temperature == 0.2)
        #expect(capped.topP == 0.9)
        #expect(capped.topK == 5)
        #expect(capped.verbose)
        #expect(capped.language == "Sinhala")
        #expect(capped.chunkDuration == 30)
        #expect(capped.minChunkDuration == 2)
        #expect(capped.repetitionPenalty == 1.1)
        #expect(capped.repetitionContextSize == 16)
        #expect(capped.kvBits == 8)
        #expect(capped.kvGroupSize == 32)
        #expect(capped.quantizedKVStart == 4)
    }
}
