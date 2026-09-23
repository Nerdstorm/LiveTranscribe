import Foundation
import HuggingFace
import MLXLLM
import MLXLMCommon

/// Loads the cleanup LLM through the Hugging Face adapters, keeping mlx-swift-lm's registry
/// settings for known models (such as Qwen3's extra end-of-sequence token).
///
/// Shared by ``MLXCleaner`` and the `Train` tool, so an adapter is trained on exactly the model
/// the app loads.
public enum CleanupModelLoader {
    /// - Parameter revision: a commit to load instead of the repository's `main`. An adapter is
    ///   only valid on the commit it was trained on.
    public static func loadContainer(
        modelID: String,
        revision: String?,
        progress: @escaping @Sendable (Progress) -> Void
    ) async throws -> ModelContainer {
        var configuration = LLMModelFactory.shared.configuration(id: modelID)
        if let revision {
            configuration.id = .id(modelID, revision: revision)
        }
        return try await LLMModelFactory.shared.loadContainer(
            from: HubDownloader(),
            using: TransformersTokenizerLoader(),
            configuration: configuration,
            progressHandler: progress
        )
    }

    /// The commit `ref` pointed to when `modelID` was last downloaded into the default Hugging
    /// Face cache, or `nil` if it is not cached.
    public static func cachedCommit(modelID: String, ref: String = "main") -> String? {
        guard let repo = Repo.ID(rawValue: modelID) else { return nil }
        return HubClient().cache?.resolveRevision(repo: repo, kind: .model, ref: ref)
    }
}
