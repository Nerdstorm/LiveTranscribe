import Foundation
import MLXLMCommon
import Shared

/// The fine-tuned LoRA adapter that teaches the cleanup model to resolve spoken
/// self-corrections, and the exact base model it was trained on.
///
/// It ships in this slice's resources (`Adapter/`) as mlx's `adapters.safetensors` and
/// `adapter_config.json`, which also records the base model and commit. It is produced by the
/// `Train` tool; see `Training/README.md`.
public struct CleanupAdapter: Sendable, Equatable {
    public static let configurationFile = "adapter_config.json"
    public static let weightsFile = "adapters.safetensors"

    /// Hugging Face id of the model the adapter was trained on.
    public let baseModel: String
    /// Commit of ``baseModel`` the adapter was trained on. It is only loaded into that commit.
    public let baseRevision: String
    public let directory: URL

    public init(baseModel: String, baseRevision: String, directory: URL) {
        self.baseModel = baseModel
        self.baseRevision = baseRevision
        self.directory = directory
    }

    /// The base-model fields `Train` adds to mlx's `adapter_config.json`.
    struct Manifest: Codable, Equatable {
        let baseModel: String
        let baseRevision: String

        enum CodingKeys: String, CodingKey {
            case baseModel = "base_model"
            case baseRevision = "base_revision"
        }
    }

    /// Reads the adapter in `directory`, or returns `nil` when it has no trained weights.
    public static func load(from directory: URL) throws -> CleanupAdapter? {
        guard FileManager.default.fileExists(atPath: directory.appending(component: weightsFile).path) else {
            return nil
        }
        let data = try Data(contentsOf: directory.appending(component: configurationFile))
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        return CleanupAdapter(baseModel: manifest.baseModel, baseRevision: manifest.baseRevision, directory: directory)
    }

    /// The adapter bundled with the app, or `nil` when none has been trained or it is unreadable.
    public static func bundled() -> CleanupAdapter? {
        guard let directory = Bundle.module.url(forResource: "Adapter", withExtension: nil) else {
            return nil
        }
        do {
            return try load(from: directory)
        } catch {
            Log.cleanup.error("The bundled cleanup adapter is unreadable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// The adapter to use with `settings`: the bundled one, when it is enabled and was trained on
    /// the configured cleanup model.
    public static func selected(for settings: AppSettings, bundled: CleanupAdapter?) -> CleanupAdapter? {
        guard settings.cleanupAdapterEnabled, let bundled else { return nil }
        guard bundled.baseModel == settings.llmModel else {
            Log.cleanup.notice(
                "Cleanup adapter skipped: trained on \(bundled.baseModel, privacy: .public), not \(settings.llmModel, privacy: .public)"
            )
            return nil
        }
        return bundled
    }

    /// The adapter as mlx-swift-lm loads it.
    func loRAContainer() throws -> LoRAContainer {
        try LoRAContainer.from(directory: directory)
    }
}
