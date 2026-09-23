import Cleanup
import Foundation
import MLXLMCommon

/// An example as model tokens: the prompt exactly as the app sends it, then the target and the
/// end-of-turn token.
public struct TokenizedExample: Sendable, Equatable {
    public let tokens: [Int]
    /// Tokens before the target. Only the target is trained on.
    public let promptLength: Int
}

public enum TrainingText {
    public enum Failure: LocalizedError {
        case noEndOfTurnToken

        public var errorDescription: String? {
            "The tokenizer has no end-of-turn token (<|im_end|> or EOS)."
        }
    }

    /// Qwen's chat template closes every turn with this token; generation stops on it.
    static let endOfTurn = "<|im_end|>"

    /// Renders `example` through the same ``Prompt/request(for:context:contextLimit:template:)``
    /// and chat template the app uses at inference, so training and inference see identical
    /// prompts.
    public static func tokenize(
        _ example: TrainingExample,
        template: PromptTemplate,
        contextLimit: Int,
        tokenizer: any Tokenizer
    ) throws -> TokenizedExample {
        let request = Prompt.request(for: example.raw, context: example.context, contextLimit: contextLimit, template: template)
        let messages: [[String: any Sendable]] = request.messages.map { ["role": $0.role.rawValue, "content": $0.content] }
        let context: [String: any Sendable] = request.templateContext.mapValues { $0 }
        let prompt = try tokenizer.applyChatTemplate(messages: messages, tools: nil, additionalContext: context)
        guard let end = tokenizer.convertTokenToId(endOfTurn) ?? tokenizer.eosTokenId else {
            throw Failure.noEndOfTurnToken
        }
        let target = tokenizer.encode(text: example.target, addSpecialTokens: false)
        return TokenizedExample(tokens: prompt + target + [end], promptLength: prompt.count)
    }
}

/// A batch of tokenized examples padded to one width, row-major, for next-token training.
struct PaddedBatch: Equatable {
    let rows: Int
    /// The longest example's length minus one: its last token is only ever a target.
    let width: Int
    let inputs: [Int32]
    /// `targets[i]` is the token that follows `inputs[i]`.
    let targets: [Int32]
    /// 1 where the target is a target-text token (or the end-of-turn token), 0 for prompt and
    /// padding positions, so only the answer is trained on.
    let mask: [Float]

    init(_ batch: [TokenizedExample]) {
        rows = batch.count
        width = max((batch.map(\.tokens.count).max() ?? 1) - 1, 1)
        var inputs = [Int32](repeating: 0, count: rows * width)
        var targets = inputs
        var mask = [Float](repeating: 0, count: rows * width)
        for (row, example) in batch.enumerated() {
            for position in 0..<max(example.tokens.count - 1, 0) {
                let index = row * width + position
                inputs[index] = Int32(example.tokens[position])
                targets[index] = Int32(example.tokens[position + 1])
                // Position p predicts token p + 1, which is a target token from promptLength on.
                mask[index] = position + 1 >= example.promptLength ? 1 : 0
            }
        }
        self.inputs = inputs
        self.targets = targets
        self.mask = mask
    }
}
