import Foundation
@preconcurrency import MLX
import MLXLLM
import MLXLMCommon
import os
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
/// measurable latency. If that fails, the base model is used, and ``PromptBuilder`` gives Light,
/// Medium and High the strict rules (Deep keeps its own prompt).
///
/// Deep's adapter (``Configuration/deepAdapter``) has the same shape, trained on the same commit,
/// so it shares the layers: its weights are swapped in for the requests that ask for it.
///
/// An adapter is in the model only for requests that ask for it (``CleanupRequest/adapter``):
/// the self-correction adapter for the levels that resolve self-corrections (Medium, High),
/// Deep's for Deep. Trained to resolve them whatever the prompt says, it would otherwise do so at
/// Light too, where every word must stay, and OutputGuard would reject the result. Otherwise the
/// layers are turned off before generating, which leaves the base model and costs no model
/// compute. Without Deep's adapter, Deep uses the self-correction adapter.
///
/// Requests are decoded greedily, except Deep's when it thinks, which are sampled as Qwen3
/// recommends for thinking, from a seed that depends only on the text.
public actor MLXCleaner: Cleaner {
    public struct Configuration: Sendable, Equatable {
        public let modelID: String
        public let contextSegments: Int
        public let timeoutSeconds: Double
        /// The self-correction adapter to load into the model, or `nil` for the base model.
        public let adapter: CleanupAdapter?
        /// Deep's adapter, or `nil` to run Deep with the self-correction adapter. It is loaded
        /// only when it was trained on the same model and commit as ``adapter``, or on its own.
        public let deepAdapter: CleanupAdapter?
        /// One prompt for every request, for prompt experiments; `nil` lets ``PromptBuilder``
        /// compose one per request from its options.
        public let promptOverride: PromptTemplate?
        /// How the Deep level runs; tools vary it to compare.
        public let deep: DeepCleanup

        public init(
            modelID: String,
            contextSegments: Int,
            timeoutSeconds: Double,
            adapter: CleanupAdapter? = nil,
            deepAdapter: CleanupAdapter? = nil,
            promptOverride: PromptTemplate? = nil,
            deep: DeepCleanup = .shipped
        ) {
            self.modelID = modelID
            self.contextSegments = contextSegments
            self.timeoutSeconds = timeoutSeconds
            self.adapter = adapter
            self.deepAdapter = deepAdapter
            self.promptOverride = promptOverride
            self.deep = deep
        }

        /// Uses the bundled adapters when the settings enable them and they match the model.
        public init(settings: AppSettings, promptOverride: PromptTemplate? = nil) {
            self.init(
                settings: settings,
                adapter: CleanupAdapter.selected(for: settings, bundled: CleanupAdapter.bundled(.medium)),
                deepAdapter: CleanupAdapter.selected(for: settings, bundled: CleanupAdapter.bundled(.deep)),
                promptOverride: promptOverride
            )
        }

        public init(
            settings: AppSettings,
            adapter: CleanupAdapter?,
            deepAdapter: CleanupAdapter? = nil,
            promptOverride: PromptTemplate? = nil,
            deep: DeepCleanup = .shipped
        ) {
            self.init(
                modelID: settings.llmModel,
                contextSegments: settings.contextSegments,
                timeoutSeconds: settings.cleanupTimeoutSeconds,
                adapter: adapter,
                deepAdapter: deepAdapter,
                promptOverride: promptOverride,
                deep: deep
            )
        }

        /// The prompts for a model with or without the adapter loaded.
        public func prompts(adapted: Bool) -> PromptBuilder {
            PromptBuilder(adapted: adapted, override: promptOverride)
        }
    }

    /// The first generation compiles kernels and can be slow; it gets a generous deadline.
    private static let warmUpTimeoutSeconds: Double = 60

    /// Sees every generation: the request, the model's whole output (reasoning included) and how
    /// long it took. For evaluation tools; the app passes none.
    /// Told of each generation: the request, with the adapter it ran with; the output; and how long
    /// it took.
    public typealias GenerationObserver = @Sendable (CleanupRequest, String, Duration) -> Void

    private let configuration: Configuration
    private let outputGuard: OutputGuard
    private let observer: GenerationObserver?
    private var executor: CleanupExecutor
    private var container: ModelContainer?
    /// The loaded adapters' layers, switched in and out per request; `nil` without an adapter.
    private var adapterLayers: AdapterLayers?
    /// The self-correction adapter in use once loaded: `nil` without one, or when loading it
    /// failed and the base model took over.
    public private(set) var activeAdapter: CleanupAdapter?
    /// Deep's adapter in use once loaded, as ``activeAdapter``.
    public private(set) var activeDeepAdapter: CleanupAdapter?

    public init(configuration: Configuration, outputGuard: OutputGuard = OutputGuard(), observer: GenerationObserver? = nil) {
        self.configuration = configuration
        self.outputGuard = outputGuard
        self.observer = observer
        self.executor = Self.executor(for: configuration, adapted: configuration.adapter != nil, outputGuard: outputGuard)
    }

    public func load(progress: @escaping ModelLoadProgressHandler) async throws {
        guard container == nil else { return }
        let modelID = configuration.modelID

        let loaded: ModelContainer
        var applied: [CleanupRequest.Adapter: CleanupAdapter] = [:]
        var layers: AdapterLayers?
        let adapters = Self.compatibleAdapters(in: configuration)
        if let pinning = adapters.values.first {
            do {
                let pinned = try await Self.loadModel(modelID, revision: pinning.baseRevision, progress: progress)
                layers = try await Self.apply(adapters, to: pinned)
                loaded = pinned
                applied = adapters.filter { layers?.adapters[$0.key] != nil }
                for (kind, adapter) in applied {
                    Log.cleanup.info(
                        "Loaded the \(kind.rawValue, privacy: .public) cleanup adapter trained on \(adapter.baseModel, privacy: .public)@\(adapter.baseRevision.prefix(7), privacy: .public)"
                    )
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                Log.cleanup.error(
                    "Cleanup adapters not used, falling back to the base model: \(error.localizedDescription, privacy: .public)"
                )
                loaded = try await Self.loadModel(modelID, revision: nil, progress: progress)
                layers = nil
            }
        } else {
            loaded = try await Self.loadModel(modelID, revision: nil, progress: progress)
        }
        try Task.checkCancellation()

        progress(ModelLoadProgress(modelID: modelID, stage: .warmingUp))
        let started = ContinuousClock.now
        let prompts = configuration.prompts(adapted: applied[.medium] != nil)
        let warmUp = Prompt.request(
            for: "this is a warm up sentence",
            context: [],
            contextLimit: 0,
            template: prompts.template(for: CleanupOptions(level: .medium)),
            adapter: applied[.medium] != nil ? .medium : .deep
        )
        let warmUpLayers = layers
        _ = try await withDeadline(seconds: Self.warmUpTimeoutSeconds) {
            try await Self.generate(with: loaded, request: warmUp, adapter: warmUpLayers)
        }
        executor = Self.executor(for: configuration, adapted: applied[.medium] != nil, outputGuard: outputGuard)
        container = loaded
        adapterLayers = layers
        activeAdapter = applied[.medium]
        activeDeepAdapter = applied[.deep]
        progress(ModelLoadProgress(modelID: modelID, stage: .ready, fractionCompleted: 1))
        Log.cleanup.info(
            "Cleanup model ready: \(modelID, privacy: .public) (warm-up \(started.duration(to: .now).wholeMilliseconds) ms)"
        )
    }

    /// Before the model has loaded, the level's deterministic rules still apply and the result
    /// is marked as a fallback.
    public func clean(_ segment: Segment, context: [String], options: CleanupOptions) async -> CleanedSegment {
        let container = self.container
        let adapter = adapterLayers
        let observer = self.observer
        return await executor.run(segment, context: context, options: options) { request in
            guard let container else { throw CleanupModelNotLoaded() }
            let started = ContinuousClock.now
            let output = try await Self.generate(with: container, request: request, adapter: adapter)
            if let observer {
                var ran = request
                ran.adapter = adapter?.resolved(request.adapter) ?? .off
                observer(ran, output, started.duration(to: .now))
            }
            return output
        }
    }

    private static func executor(for configuration: Configuration, adapted: Bool, outputGuard: OutputGuard) -> CleanupExecutor {
        CleanupExecutor(
            contextLimit: configuration.contextSegments,
            timeoutSeconds: configuration.timeoutSeconds,
            outputGuard: outputGuard,
            prompts: configuration.prompts(adapted: adapted),
            deep: configuration.deep
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

    /// The configured adapters that can be loaded together: trained on the configured model, and
    /// Deep's only on the self-correction adapter's commit, since they share the pinned model.
    public static func compatibleAdapters(in configuration: Configuration) -> [CleanupRequest.Adapter: CleanupAdapter] {
        var adapters: [CleanupRequest.Adapter: CleanupAdapter] = [:]
        if let medium = configuration.adapter {
            adapters[.medium] = medium
        }
        if let deep = configuration.deepAdapter {
            if let medium = configuration.adapter, (deep.baseModel, deep.baseRevision) != (medium.baseModel, medium.baseRevision) {
                Log.cleanup.error(
                    "Deep's cleanup adapter not used: trained on \(deep.baseModel, privacy: .public)@\(deep.baseRevision.prefix(7), privacy: .public), the self-correction adapter on \(medium.baseModel, privacy: .public)@\(medium.baseRevision.prefix(7), privacy: .public)"
                )
            } else {
                adapters[.deep] = deep
            }
        }
        return adapters
    }

    /// Loads the adapters' layers into the model and turns the first on. An adapter whose layers
    /// differ from the first's is left out.
    private static func apply(_ adapters: [CleanupRequest.Adapter: CleanupAdapter], to container: ModelContainer) async throws -> AdapterLayers {
        var loRAs: [CleanupRequest.Adapter: LoRAContainer] = [:]
        for kind in CleanupRequest.Adapter.allCases {
            guard let adapter = adapters[kind] else { continue }
            let loRA = try adapter.loRAContainer()
            if let first = loRAs.values.first, !AdapterLayers.shareLayers(first, loRA) {
                Log.cleanup.error("The \(kind.rawValue, privacy: .public) cleanup adapter not used: its layers differ from the other adapter's")
                continue
            }
            loRAs[kind] = loRA
        }
        let layers = AdapterLayers(adapters: loRAs)
        let first = CleanupRequest.Adapter.allCases.first { loRAs[$0] != nil } ?? .off
        try await container.perform(values: layers) { context, layers in
            try layers.use(first, in: context.model)
            eval(context.model)
        }
        return layers
    }

    /// Generation of the corrected text, as the request's sampling says. Cancelling the calling
    /// task stops generation: the token stream ends and mlx-swift-lm cancels its generation task.
    ///
    /// The adapter is switched in or out inside the same `perform` as the generation, so no
    /// other request can change the model in between.
    private static func generate(
        with container: ModelContainer,
        request: CleanupRequest,
        adapter: AdapterLayers?
    ) async throws -> String {
        try await container.perform(values: request) { context, request in
            if let adapter {
                do {
                    try adapter.use(request.adapter, in: context.model)
                } catch {
                    // The base model still cleans up; the prompt's rules and OutputGuard hold.
                    Log.cleanup.error("Could not switch the cleanup adapter: \(error.localizedDescription, privacy: .public)")
                }
            }
            let chat: [Chat.Message] = request.messages.map { message in
                switch message.role {
                case .system: .system(message.content)
                case .user: .user(message.content)
                case .assistant: .assistant(message.content)
                }
            }
            let input = UserInput(chat: chat, additionalContext: request.templateContext)
            let prepared = try await context.processor.prepare(input: input)
            let sampling = request.sampling
            let parameters = GenerateParameters(
                maxTokens: request.maxTokens,
                temperature: sampling.temperature,
                topP: sampling.topP,
                topK: sampling.topK,
                seed: sampling.seed
            )

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

/// LoRA adapters of one shape, whose layers are loaded into the model once; per request, the
/// layers are turned off, or on with one adapter's weights.
///
/// Only used inside `ModelContainer.perform`, which runs one closure at a time; the lock makes
/// the state safe to share with those closures, not to switch concurrently.
final class AdapterLayers: Sendable {
    let adapters: [CleanupRequest.Adapter: LoRAContainer]
    /// Whose weights are in the layers and whether they are on; `nil` until the layers are in the
    /// model.
    private let state = OSAllocatedUnfairLock<(weights: CleanupRequest.Adapter, on: Bool)?>(initialState: nil)

    init(adapters: [CleanupRequest.Adapter: LoRAContainer]) {
        self.adapters = adapters
    }

    /// Whether two adapters fit the same layers: the same layers, projections, rank and scale.
    static func shareLayers(_ lhs: LoRAContainer, _ rhs: LoRAContainer) -> Bool {
        let (a, b) = (lhs.configuration, rhs.configuration)
        return a.numLayers == b.numLayers && a.fineTuneType == b.fineTuneType
            && a.loraParameters.rank == b.loraParameters.rank && a.loraParameters.scale == b.loraParameters.scale
            && a.loraParameters.keys == b.loraParameters.keys
    }

    /// The adapter a request for `wanted` runs with (``CleanupRequest/Adapter/resolved(loaded:)``).
    func resolved(_ wanted: CleanupRequest.Adapter) -> CleanupRequest.Adapter {
        wanted.resolved(loaded: Set(adapters.keys))
    }

    /// Loads the layers the first time; after that, swaps in the wanted adapter's weights when
    /// another's are there, and turns the layers on or off with mlx-swift-lm's per-layer toggle,
    /// which leaves the base weights untouched. Does nothing when the model is already that way.
    func use(_ wanted: CleanupRequest.Adapter, in model: any LanguageModel) throws {
        let target = resolved(wanted)
        let current = state.withLock { $0 }
        if target == .off {
            guard let current, current.on else { return }
            model.setLoRAEnabled(false)
            state.withLock { $0 = (current.weights, false) }
            Log.cleanup.debug("Cleanup adapter off")
            return
        }
        guard let loRA = adapters[target] else { return }
        if current == nil {
            try model.load(adapter: loRA)
        } else if current?.weights != target {
            try model.update(parameters: loRA.parameters, verify: [.noUnusedKeys, .shapeMismatch])
        }
        if current?.on != true {
            model.setLoRAEnabled(true)
        }
        state.withLock { $0 = (target, true) }
        Log.cleanup.debug("Cleanup adapter \(target.rawValue, privacy: .public) on")
    }
}

/// A cleanup was requested before ``MLXCleaner/load(progress:)`` finished.
struct CleanupModelNotLoaded: LocalizedError {
    var errorDescription: String? { "cleanup model not loaded" }
}
