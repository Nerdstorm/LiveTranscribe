@testable import Cleanup
import Foundation
import Shared
import Testing

@Suite("CleanupAdapter")
struct CleanupAdapterTests {
    private let commit = "0123456789abcdef0123456789abcdef01234567"

    /// A throwaway adapter folder with mlx's configuration and, optionally, a weights file.
    private func adapterDirectory(model: String = AppSettings.defaults.llmModel, weights: Bool = true) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(component: "CleanupAdapterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configuration = """
            {"fine_tune_type": "lora", "num_layers": 16, "lora_parameters": {"rank": 8, "scale": 20.0},
             "base_model": "\(model)", "base_revision": "\(commit)"}
            """
        try configuration.write(to: directory.appending(component: CleanupAdapter.configurationFile), atomically: true, encoding: .utf8)
        if weights {
            try Data().write(to: directory.appending(component: CleanupAdapter.weightsFile))
        }
        return directory
    }

    @Test func readsTheBaseModelAndCommitFromTheConfiguration() throws {
        let directory = try adapterDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let adapter = try #require(try CleanupAdapter.load(from: directory))
        #expect(adapter.baseModel == AppSettings.defaults.llmModel)
        #expect(adapter.baseRevision == commit)
    }

    @Test func aFolderWithoutWeightsHasNoAdapter() throws {
        let directory = try adapterDirectory(weights: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try CleanupAdapter.load(from: directory) == nil)
    }

    @Test func isUsedOnlyWhenEnabledAndTrainedOnTheConfiguredModel() throws {
        let directory = try adapterDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let adapter = try #require(try CleanupAdapter.load(from: directory))
        var settings = AppSettings.defaults

        #expect(CleanupAdapter.selected(for: settings, bundled: adapter) == adapter)
        #expect(CleanupAdapter.selected(for: settings, bundled: nil) == nil)
        settings.cleanupAdapterEnabled = false
        #expect(CleanupAdapter.selected(for: settings, bundled: adapter) == nil)
        settings.cleanupAdapterEnabled = true
        settings.llmModel = "mlx-community/Qwen3-4B-4bit"
        #expect(CleanupAdapter.selected(for: settings, bundled: adapter) == nil)
    }

    @Test func theBundledAdapterMatchesTheDefaultModel() throws {
        let adapter = try #require(CleanupAdapter.bundled(), "the trained adapter ships in Sources/Cleanup/Adapter")
        #expect(adapter.baseModel == AppSettings.defaults.llmModel)
        #expect(adapter.baseRevision.count == 40, "pinned to a commit, not a branch")
        #expect(CleanupAdapter.selected(for: .defaults, bundled: adapter) == adapter)
        _ = try adapter.loRAContainer()
    }

    @Test func theAdapterGetsThePromptItWasTrainedOn() throws {
        let adapter = CleanupAdapter(baseModel: "m", baseRevision: commit, directory: URL(fileURLWithPath: "/"))
        let withAdapter = MLXCleaner.Configuration(modelID: "m", contextSegments: 3, timeoutSeconds: 1, adapter: adapter)
        let without = MLXCleaner.Configuration(modelID: "m", contextSegments: 3, timeoutSeconds: 1)
        let explicit = MLXCleaner.Configuration(modelID: "m", contextSegments: 3, timeoutSeconds: 1, adapter: adapter, template: Prompt.cleanup)
        #expect(withAdapter.template == Prompt.adapted)
        #expect(without.template == Prompt.cleanup)
        #expect(explicit.template == Prompt.cleanup)
    }
}
