import Foundation
import Shared

/// Everything the cleanup model is asked, as plain Sendable values.
public struct CleanupRequest: Sendable, Equatable {
    public enum Role: String, Sendable, Equatable {
        case system
        case user
        case assistant
    }

    public struct Message: Sendable, Equatable {
        public let role: Role
        public let content: String

        public init(role: Role, content: String) {
            self.role = role
            self.content = content
        }
    }

    /// Which fine-tuned adapter is on for a request (see ``MLXCleaner``).
    public enum Adapter: String, Sendable, Equatable, CaseIterable, Codable {
        /// The base model.
        case off = "none"
        /// The self-correction adapter, trained on Medium's prompt (``Prompt/adapted``).
        case medium
        /// Deep's adapter, trained on Deep's prompts.
        case deep
    }

    public let messages: [Message]
    /// Variables for the chat template (see ``Prompt/templateContext``).
    public let templateContext: [String: Bool]
    public let maxTokens: Int
    public var adapter: Adapter
    /// How the next token is chosen.
    public var sampling: Sampling

    public init(
        messages: [Message],
        templateContext: [String: Bool],
        maxTokens: Int,
        adapter: Adapter = .off,
        sampling: Sampling = .greedy
    ) {
        self.messages = messages
        self.templateContext = templateContext
        self.maxTokens = maxTokens
        self.adapter = adapter
        self.sampling = sampling
    }

    /// The model reasons in a `<think>` block before it answers (Deep, when thinking is on).
    public var thinks: Bool { templateContext[Prompt.thinkingKey] == true }

    /// How tokens are chosen: greedy, or Qwen3's recommended sampling while thinking.
    public struct Sampling: Sendable, Equatable {
        public var temperature: Float
        public var topP: Float
        public var topK: Int
        /// Seeds the sampler, so the same text always gets the same answer; unused when greedy.
        public var seed: UInt64?

        public init(temperature: Float, topP: Float, topK: Int, seed: UInt64?) {
            self.temperature = temperature
            self.topP = topP
            self.topK = topK
            self.seed = seed
        }

        public static let greedy = Sampling(temperature: 0, topP: 1, topK: 0, seed: nil)

        /// Qwen3's settings for thinking mode, where greedy decoding tends to repeat itself.
        public static func thinking(seed: UInt64) -> Sampling {
            Sampling(temperature: 0.6, topP: 0.95, topK: 20, seed: seed)
        }
    }
}

/// The system instruction and worked examples that frame every cleanup request.
public struct PromptTemplate: Sendable, Equatable {
    /// A raw text and its cleaned version, sent as an answered turn.
    public struct Example: Sendable, Equatable {
        public let text: String
        public let cleaned: String

        public init(text: String, cleaned: String) {
            self.text = text
            self.cleaned = cleaned
        }
    }

    public let system: String
    public let examples: [Example]

    public init(system: String, examples: [Example]) {
        self.system = system
        self.examples = examples
    }
}

/// The cleanup prompt: the template's system instruction and examples, then prior segments as
/// already-answered turns (read-only context), then the segment to fix as the final user turn.
///
/// Context goes in earlier turns rather than in the final message because a small model asked
/// to correct "CONTEXT + TEXT" in one message tends to return both, which the output guard then
/// has to reject.
public enum Prompt {
    /// Strict correction, the Light level's prompt and every level's without the adapter: the
    /// model is told to remove nothing, so spoken self-corrections normally stay as said
    /// ("cars, sorry, buses"). Asking Qwen3-1.7B to resolve them, by
    /// instruction or by worked examples, resolved at most 1 in 7 correctly, usually kept the
    /// retracted words instead of the correction, and made it drop hedges such as "I think"
    /// elsewhere. At Medium and High, ``OutputGuard`` still accepts a correct resolution if the
    /// model makes one.
    public static let cleanup = PromptBuilder(adapted: false).template(for: CleanupOptions(level: .light))

    /// Used with the bundled fine-tuned adapter (``CleanupAdapter``), which was trained on
    /// exactly this prompt: the Medium level's. The one removal it allows is a spoken
    /// self-correction; the adapter supplies the ability the base model lacks, and
    /// ``OutputGuard`` checks that nothing else was removed.
    public static let adapted = PromptBuilder(adapted: true).template(for: CleanupOptions(level: .medium))

    /// Qwen3's chat template reads `enable_thinking`. Thinking is off at every level but Deep's
    /// thinking mode: with it on, latency grows by seconds and the `<think>` block has to be removed
    /// from the output (``ThinkingOutput``).
    public static let thinkingKey = "enable_thinking"
    public static let templateContext: [String: Bool] = [thinkingKey: false]
    static let thinkingTemplateContext: [String: Bool] = [thinkingKey: true]

    /// Output budget: two tokens per input word plus a fixed allowance for punctuation, plus room
    /// for each placeholder, whose brackets take several tokens each.
    public static let maxTokensPerInputWord = 2
    public static let maxTokensAllowance = 16
    public static let maxTokensPerPlaceholder = 6

    /// - Parameters:
    ///   - adapter: the fine-tuned adapter on for this request.
    ///   - thinkingTokens: when not `nil`, the model thinks first, with this many tokens for its
    ///     reasoning on top of the answer's budget, sampled as Qwen3 recommends.
    public static func request(
        for text: String,
        context: [String],
        contextLimit: Int,
        template: PromptTemplate = cleanup,
        adapter: CleanupRequest.Adapter = .off,
        thinkingTokens: Int? = nil
    ) -> CleanupRequest {
        var messages = [CleanupRequest.Message(role: .system, content: template.system)]
        for example in template.examples {
            messages.append(CleanupRequest.Message(role: .user, content: userMessage(for: example.text)))
            messages.append(CleanupRequest.Message(role: .assistant, content: example.cleaned))
        }
        for previous in contextWindow(context, limit: contextLimit) {
            messages.append(CleanupRequest.Message(role: .user, content: userMessage(for: previous)))
            messages.append(CleanupRequest.Message(role: .assistant, content: previous))
        }
        messages.append(CleanupRequest.Message(role: .user, content: userMessage(for: text)))
        guard let thinkingTokens else {
            return CleanupRequest(messages: messages, templateContext: templateContext, maxTokens: maxTokens(for: text), adapter: adapter)
        }
        return CleanupRequest(
            messages: messages,
            templateContext: thinkingTemplateContext,
            maxTokens: maxTokens(for: text) + thinkingTokens,
            adapter: adapter,
            sampling: .thinking(seed: seed(for: text))
        )
    }

    /// A seed that depends only on `text` (FNV-1a over its UTF-8), so sampling is repeatable.
    static func seed(for text: String) -> UInt64 {
        text.utf8.reduce(14_695_981_039_346_656_037 as UInt64) { hash, byte in
            (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }

    /// The most recent `limit` non-empty context segments, oldest first.
    public static func contextWindow(_ context: [String], limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        let nonEmpty = context
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Array(nonEmpty.suffix(limit))
    }

    public static func maxTokens(for text: String) -> Int {
        EditDistance.words(in: text).count * maxTokensPerInputWord
            + PlaceholderToken.openingCount(in: text) * maxTokensPerPlaceholder
            + maxTokensAllowance
    }

    static func userMessage(for text: String) -> String {
        "TEXT:\n\(text)"
    }
}
