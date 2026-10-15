import Foundation
@preconcurrency import MLX
import MLXAudioSTT

/// The masks a ``ScriptLock`` puts on Qwen3-ASR's logits: 0 on each token it allows and −∞ on the
/// rest. Each is made the first time a language and an unfinished character need it, which takes
/// a few milliseconds over the 151,643 tokens, and kept while the model is loaded.
final class LockedLogits {
    let vocabulary: LockedVocabulary
    private var masks: [Key: MLXArray] = [:]

    private struct Key: Hashable {
        let lock: ScriptLock
        let partial: PartialCharacter
        let logitCount: Int
    }

    init(vocabulary: LockedVocabulary) {
        self.vocabulary = vocabulary
    }

    /// `logits` (the last token's, `[1, vocabulary]`) with what `lock` forbids after `partial`
    /// taken out.
    func locking(_ logits: MLXArray, by lock: ScriptLock, after partial: PartialCharacter) -> MLXArray {
        let key = Key(lock: lock, partial: partial, logitCount: logits.dim(-1))
        let mask: MLXArray
        if let made = masks[key] {
            mask = made
        } else {
            let allowed = vocabulary.allowed(by: lock, after: partial, logitCount: key.logitCount)
            mask = MLXArray(allowed.map { $0 ? Float(0) : -Float.infinity })
            masks[key] = mask
        }
        return logits.asType(.float32) + mask
    }
}

extension Qwen3ASRModel {
    /// The tokens that end a reply: `<|im_end|>` and `<|endoftext|>`.
    static let endOfReply: Set<Int> = [151_645, 151_643]

    /// Transcribes `audio` told the language `parameters` names, writing only what `lock`
    /// allows: mlx-audio-swift's `generate(audio:generationParameters:)` (as at 01dec7c), step for
    /// step, with the lock's mask on the logits before each greedy choice.
    ///
    /// As there: the audio is split at quiet points into chunks of `chunkDuration` at most, and
    /// each chunk's reply ends at an end-of-reply token, at the tokens left of `maxTokens`, or, with
    /// no repetition penalty, once its last 24 tokens hold 3 or fewer different tokens.
    func generate(
        audio: MLXArray,
        parameters: STTGenerateParameters,
        locking lock: ScriptLock,
        with logits: LockedLogits
    ) -> (text: String, generationTokens: Int) {
        guard let tokenizer else { return ("", 0) }
        let chunks = splitAudioIntoChunks(
            audio,
            sampleRate: sampleRate,
            chunkDuration: parameters.chunkDuration,
            minChunkDuration: parameters.minChunkDuration
        )
        var texts: [String] = []
        var generationTokens = 0
        for (chunk, _) in chunks {
            let remaining = parameters.maxTokens - generationTokens
            guard remaining > 0 else { break }
            let tokens = reply(to: chunk, parameters: parameters, maxTokens: remaining, locking: lock, with: logits)
            texts.append(tokenizer.decode(tokens: tokens).trimmingCharacters(in: .whitespacesAndNewlines))
            generationTokens += tokens.count
            Memory.clearCache()
        }
        return (texts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines), generationTokens)
    }

    /// One chunk's reply, as mlx-audio-swift's `generateSingleChunk` decodes it, locked.
    private func reply(
        to audio: MLXArray,
        parameters: STTGenerateParameters,
        maxTokens: Int,
        locking lock: ScriptLock,
        with lockedLogits: LockedLogits
    ) -> [Int] {
        let (features, featureMask, audioTokenCount) = preprocessAudio(audio)
        let prompt = buildPrompt(numAudioTokens: audioTokenCount, context: "", language: parameters.language)
        let cache = makeCache()
        // The prompt in one pass, which merges the audio's features in; mlx-audio-swift takes it
        // 2,048 tokens at a time, which a dictation's prompt never reaches.
        var last = self(inputIds: prompt, inputFeatures: features, featureAttentionMask: featureMask, cache: cache)[0..., -1, 0...]
        var tokens: [Int] = []
        var partial = PartialCharacter.nothing
        while tokens.count < maxTokens {
            let token = lockedLogits.locking(last, by: lock, after: partial).argMax(axis: -1).item(Int.self)
            if Self.endOfReply.contains(token) { break }
            tokens.append(token)
            // The mask allowed the token, so the lock reads it.
            partial = lock.partial(after: partial, reading: lockedLogits.vocabulary.bytes(of: token)) ?? .nothing
            if parameters.repetitionPenalty == 1, tokens.count >= 24, Set(tokens.suffix(24)).count <= 3 { break }
            if tokens.count == maxTokens { break }

            last = self(inputIds: MLXArray([Int32(token)]).expandedDimensions(axis: 0), cache: cache)[0..., -1, 0...]
            if parameters.repetitionPenalty != 1 {
                let recent = MLXArray(tokens.suffix(max(1, parameters.repetitionContextSize)).map { Int32($0) })
                let recentLogits = last[0..., recent]
                let penalty = MLXArray(parameters.repetitionPenalty)
                last[0..., recent] = MLX.where(recentLogits .> 0, recentLogits / penalty, recentLogits * penalty)
            }
            if tokens.count % 256 == 0 {
                Memory.clearCache()
            }
        }
        return tokens
    }
}
