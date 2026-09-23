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
///
/// With a ``CleanupAdapter``, the model is loaded at the commit the adapter was trained on and
/// the adapter is fused into its weights, so generation costs the same as without it. If that
/// fails, the base model is used, and ``PromptBuilder`` gives every level the strict rules.
public actor MLXCleaner: Cleaner {
    public struct Configuration: Sendable, Equatable {
        public let modelID: String
        public let contextSegments: Int
        public let timeoutSeconds: Double
        /// Fine-tuned adapter to fuse into the model, or `nil` for the base model.
        public let adapter: CleanupAdapter?
        /// One prompt for every request, for prompt experiments; `nil` lets ``PromptBuilder``
        /// compose one per request from its options.
        public let promptOverride: PromptTemplate?

        public init(
            modelID: String,
            contextSegments: Int,
            timeoutSeconds: Double,
            adapter: CleanupAdapter? = nil,
            promptOverride: PromptTemplate? = nil
        ) {
            self.modelID = modelID
            self.contextSegments = contextSegments
            self.timeoutSeconds = timeoutSeconds
            self.adapter = adapter
            self.promptOverride = promptOverride
        }

        /// Uses the bundled adapter when the settings enable it and it matches the model.
        public init(settings: AppSettings, promptOverride: PromptTemplate? = nil) {
            self.init(
                settings: settings,
                adapter: CleanupAdapter.selected(for: settings, bundled: CleanupAdapter.bundled()),
                promptOverride: promptOverride
            )
        }

        public init(settings: AppSettings, adapter: CleanupAdapter?, promptOverride: PromptTemplate? = nil) {
            self.init(
                modelID: settings.llmModel,
                contextSegments: settings.contextSegments,
                timeoutSeconds: settings.cleanupTimeoutSeconds,
                adapter: adapter,
                promptOverride: promptOverride
            )
        }

        /// The prompts for a model with or without the adapter fused in.
        public func prompts(adapted: Bool) -> PromptBuilder {
            PromptBuilder(adapted: adapted, override: promptOverride)
        }
    }

    /// The first generation compiles kernels and can be slow; it gets a generous deadline.
    private static let warmUpTimeoutSeconds: Double = 60

    private let configuration: Configuration
    private let outputGuard: OutputGuard
    private var executor: CleanupExecutor
    private var container: ModelContainer?
    /// The adapter in use once loaded: `nil` without one, or when loading it failed and the
    /// base model took over.
    public private(set) var activeAdapter: CleanupAdapter?

    public init(configuration: Configuration, outputGuard: OutputGuard = OutputGuard()) {
        self.configuration = configuration
        self.outputGuard = outputGuard
        self.executor = Self.executor(for: configuration, adapted: configuration.adapter != nil, outputGuard: outputGuard)
    }

    public func load(progress: @escaping ModelLoadProgressHandler) async throws {
        guard container == nil else { return }
        let modelID = configuration.modelID

        let loaded: ModelContainer
        var applied: CleanupAdapter?
        if let adapter = configuration.adapter {
            do {
                let pinned = try await Self.loadModel(modelID, revision: adapter.baseRevision, progress: progress)
                try await Self.fuse(adapter, into: pinned)
                loaded = pinned
                applied = adapter
                Log.cleanup.info(
                    "Fused the cleanup adapter trained on \(adapter.baseModel, privacy: .public)@\(adapter.baseRevision.prefix(7), privacy: .public)"
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                Log.cleanup.error(
                    "Cleanup adapter not used, falling back to the base model: \(error.localizedDescription, privacy: .public)"
                )
                loaded = try await Self.loadModel(modelID, revision: nil, progress: progress)
            }
        } else {
            loaded = try await Self.loadModel(modelID, revision: nil, progress: progress)
        }
        try Task.checkCancellation()

        progress(ModelLoadProgress(modelID: modelID, stage: .warmingUp))
        let started = ContinuousClock.now
        let prompts = configuration.prompts(adapted: applied != nil)
        let warmUp = Prompt.request(
            for: "this is a warm up sentence",
            context: [],
            contextLimit: 0,
            template: prompts.template(for: CleanupOptions(level: .medium))
        )
        _ = try await withDeadline(seconds: Self.warmUpTimeoutSeconds) {
            try await Self.generate(with: loaded, request: warmUp)
        }
        executor = Self.executor(for: configuration, adapted: applied != nil, outputGuard: outputGuard)
        container = loaded
        activeAdapter = applied
        progress(ModelLoadProgress(modelID: modelID, stage: .ready, fractionCompleted: 1))
        Log.cleanup.info(
            "Cleanup model ready: \(modelID, privacy: .public) (warm-up \(started.duration(to: .now).wholeMilliseconds) ms)"
        )
    }

    /// Before the model has loaded, the level's deterministic rules still apply and the result
    /// is marked as a fallback.
    public func clean(_ segment: Segment, context: [String], options: CleanupOptions) async -> CleanedSegment {
        let container = self.container
        return await executor.run(segment, context: context, options: options) { request in
            guard let container else { throw CleanupModelNotLoaded() }
            return try await Self.generate(with: container, request: request)
        }
    }

    private static func executor(for configuration: Configuration, adapted: Bool, outputGuard: OutputGuard) -> CleanupExecutor {
        CleanupExecutor(
            contextLimit: configuration.contextSegments,
            timeoutSeconds: configuration.timeoutSeconds,
            outputGuard: outputGuard,
            prompts: configuration.prompts(adapted: adapted)
        )
    }

    private static func loadModel(
        _ modelID: String,
        revision: String?,
        progress: @escaping ModelLoadProgressHandler
    ) async throws -> ModelContainer {
        progress(ModelLoadProgress(modelID: modelID, stage: .downloading, fractionCompleted: 0))
        return try await CleanupModelLoader.loadContainer(modelID: modelID, revision: revision) { downloadProgress in
            progress(ModelLoadProgress(
                modelID: modelID,
                stage: .downloading,
                fractionCompleted: downloadProgress.fractionCompleted
            ))
        }
    }

    private static func fuse(_ adapter: CleanupAdapter, into container: ModelContainer) async throws {
        let lora = try adapter.loRAContainer()
        try await container.perform(values: lora) { context, lora in
            try context.model.fuse(with: lora)
            eval(context.model)
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

/// A cleanup was requested before ``MLXCleaner/load(progress:)`` finished.
struct CleanupModelNotLoaded: LocalizedError {
    var errorDescription: String? { "cleanup model not loaded" }
}
