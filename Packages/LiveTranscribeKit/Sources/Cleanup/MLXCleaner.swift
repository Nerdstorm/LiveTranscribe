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
/// the adapter's LoRA layers are loaded alongside its weights. It is not fused into them: fusing
/// re-quantizes each weight to 4 bits, which rounds away most of the adapter's small change
/// (held-out self-corrections resolved: 97% unfused, 13% fused). The unfused layers add no
/// measurable latency. If that
/// fails, the base model is used with the strict ``Prompt/cleanup`` prompt instead.
public actor MLXCleaner: Cleaner {
    public struct Configuration: Sendable, Equatable {
        public let modelID: String
        public let contextSegments: Int
        public let timeoutSeconds: Double
        /// Fine-tuned adapter to load into the model, or `nil` for the base model.
        public let adapter: CleanupAdapter?
        /// The prompt: ``Prompt/adapted`` with an adapter, ``Prompt/cleanup`` without, unless
        /// given explicitly (for prompt experiments).
        public let template: PromptTemplate

        public init(
            modelID: String,
            contextSegments: Int,
            timeoutSeconds: Double,
            adapter: CleanupAdapter? = nil,
            template: PromptTemplate? = nil
        ) {
            self.modelID = modelID
            self.contextSegments = contextSegments
            self.timeoutSeconds = timeoutSeconds
            self.adapter = adapter
            self.template = template ?? (adapter == nil ? Prompt.cleanup : Prompt.adapted)
        }

        /// Uses the bundled adapter when the settings enable it and it matches the model.
        public init(settings: AppSettings, template: PromptTemplate? = nil) {
            self.init(
                settings: settings,
                adapter: CleanupAdapter.selected(for: settings, bundled: CleanupAdapter.bundled()),
                template: template
            )
        }

        public init(settings: AppSettings, adapter: CleanupAdapter?, template: PromptTemplate? = nil) {
            self.init(
                modelID: settings.llmModel,
                contextSegments: settings.contextSegments,
                timeoutSeconds: settings.cleanupTimeoutSeconds,
                adapter: adapter,
                template: template
            )
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
        self.executor = Self.executor(for: configuration, template: configuration.template, outputGuard: outputGuard)
    }

    public func load(progress: @escaping ModelLoadProgressHandler) async throws {
        guard container == nil else { return }
        let modelID = configuration.modelID

        let loaded: ModelContainer
        var template = configuration.template
        var applied: CleanupAdapter?
        if let adapter = configuration.adapter {
            do {
                let pinned = try await Self.loadModel(modelID, revision: adapter.baseRevision, progress: progress)
                try await Self.apply(adapter, to: pinned)
                loaded = pinned
                applied = adapter
                Log.cleanup.info(
                    "Loaded the cleanup adapter trained on \(adapter.baseModel, privacy: .public)@\(adapter.baseRevision.prefix(7), privacy: .public)"
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                Log.cleanup.error(
                    "Cleanup adapter not used, falling back to the base model: \(error.localizedDescription, privacy: .public)"
                )
                loaded = try await Self.loadModel(modelID, revision: nil, progress: progress)
                template = Prompt.cleanup
            }
        } else {
            loaded = try await Self.loadModel(modelID, revision: nil, progress: progress)
        }
        try Task.checkCancellation()

        progress(ModelLoadProgress(modelID: modelID, stage: .warmingUp))
        let started = ContinuousClock.now
        let warmUp = Prompt.request(for: "this is a warm up sentence", context: [], contextLimit: 0, template: template)
        _ = try await withDeadline(seconds: Self.warmUpTimeoutSeconds) {
            try await Self.generate(with: loaded, request: warmUp)
        }
        executor = Self.executor(for: configuration, template: template, outputGuard: outputGuard)
        container = loaded
        activeAdapter = applied
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

    private static func executor(for configuration: Configuration, template: PromptTemplate, outputGuard: OutputGuard) -> CleanupExecutor {
        CleanupExecutor(
            contextLimit: configuration.contextSegments,
            timeoutSeconds: configuration.timeoutSeconds,
            outputGuard: outputGuard,
            template: template
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

    private static func apply(_ adapter: CleanupAdapter, to container: ModelContainer) async throws {
        let lora = try adapter.loRAContainer()
        try await container.perform(values: lora) { context, lora in
            try context.model.load(adapter: lora)
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
