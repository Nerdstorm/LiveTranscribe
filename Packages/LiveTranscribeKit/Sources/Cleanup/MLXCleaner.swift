import Foundation
@preconcurrency import MLX
import MLXLLM
import MLXLMCommon
import Shared

/// ``Cleaner`` backed by an MLX LLM (Qwen3-1.7B-4bit by default) via mlx-swift-lm.
///
/// The `ModelContainer` is held here and every MLX value stays inside `ModelContainer.perform`;
/// only strings cross the boundary. Segments are cleaned one at a time: the caller awaits each
/// `clean` before sending the next, and the container serialises access to the model.
public actor MLXCleaner: Cleaner {
    public struct Configuration: Sendable, Equatable {
        public let modelID: String
        public let contextSegments: Int
        public let timeoutSeconds: Double
        public let template: PromptTemplate

        public init(modelID: String, contextSegments: Int, timeoutSeconds: Double, template: PromptTemplate = Prompt.cleanup) {
            self.modelID = modelID
            self.contextSegments = contextSegments
            self.timeoutSeconds = timeoutSeconds
            self.template = template
        }

        public init(settings: AppSettings, template: PromptTemplate = Prompt.cleanup) {
            self.init(
                modelID: settings.llmModel,
                contextSegments: settings.contextSegments,
                timeoutSeconds: settings.cleanupTimeoutSeconds,
                template: template
            )
        }
    }

    /// The first generation compiles kernels and can be slow; it gets a generous deadline.
    private static let warmUpTimeoutSeconds: Double = 60

    private let configuration: Configuration
    private let executor: CleanupExecutor
    private var container: ModelContainer?

    public init(configuration: Configuration, outputGuard: OutputGuard = OutputGuard()) {
        self.configuration = configuration
        self.executor = CleanupExecutor(
            contextLimit: configuration.contextSegments,
            timeoutSeconds: configuration.timeoutSeconds,
            outputGuard: outputGuard,
            template: configuration.template
        )
    }

    public func load(progress: @escaping ModelLoadProgressHandler) async throws {
        guard container == nil else { return }
        let modelID = configuration.modelID

        progress(ModelLoadProgress(modelID: modelID, stage: .downloading, fractionCompleted: 0))
        let loaded = try await LLMModelFactory.shared.loadContainer(
            from: HubDownloader(),
            using: TransformersTokenizerLoader(),
            configuration: LLMModelFactory.shared.configuration(id: modelID)
        ) { downloadProgress in
            progress(ModelLoadProgress(
                modelID: modelID,
                stage: .downloading,
                fractionCompleted: downloadProgress.fractionCompleted
            ))
        }
        try Task.checkCancellation()

        progress(ModelLoadProgress(modelID: modelID, stage: .warmingUp))
        let started = ContinuousClock.now
        let warmUp = Prompt.request(for: "this is a warm up sentence", context: [], contextLimit: 0, template: configuration.template)
        _ = try await withDeadline(seconds: Self.warmUpTimeoutSeconds) {
            try await Self.generate(with: loaded, request: warmUp)
        }
        container = loaded
        progress(ModelLoadProgress(modelID: modelID, stage: .ready, fractionCompleted: 1))
        Log.cleanup.info(
            "Cleanup model ready: \(modelID, privacy: .public) (warm-up \(started.duration(to: .now).wholeMilliseconds) ms)"
        )
    }

    public func clean(_ segment: Segment, context: [String]) async -> CleanedSegment {
        guard let container else {
            return .fallback(segment, reason: "cleanup model not loaded", latencyMs: 0)
        }
        return await executor.run(segment, context: context) { request in
            try await Self.generate(with: container, request: request)
        }
    }

    /// Greedy generation of the corrected text. Cancelling the calling task stops generation:
    /// the token stream ends and mlx-swift-lm cancels its generation task.
    private static func generate(with container: ModelContainer, request: CleanupRequest) async throws -> String {
        try await container.perform(values: request) { context, request in
            let chat: [Chat.Message] = request.messages.map { message in
                switch message.role {
                case .system: .system(message.content)
                case .user: .user(message.content)
                case .assistant: .assistant(message.content)
                }
            }
            let input = UserInput(chat: chat, additionalContext: request.templateContext)
            let prepared = try await context.processor.prepare(input: input)
            let parameters = GenerateParameters(maxTokens: request.maxTokens, temperature: 0)

            var text = ""
            for await generation in try MLXLMCommon.generate(input: prepared, parameters: parameters, context: context) {
                if case .chunk(let chunk) = generation {
                    text += chunk
                }
            }
            try Task.checkCancellation()
            return text
        }
    }
}
