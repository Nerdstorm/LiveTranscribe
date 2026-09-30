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

    @Test(arguments: [CleanupRequest.Adapter.medium, .deep])
    func theBundledAdaptersMatchTheDefaultModel(_ kind: CleanupRequest.Adapter) throws {
        let adapter = try #require(CleanupAdapter.bundled(kind), "the trained adapters ship in Sources/Cleanup")
        #expect(adapter.baseModel == AppSettings.defaults.llmModel)
        #expect(adapter.baseRevision.count == 40, "pinned to a commit, not a branch")
        #expect(CleanupAdapter.selected(for: .defaults, bundled: adapter) == adapter)
        _ = try adapter.loRAContainer()
    }

    @Test func theBundledAdaptersShareTheirModelAndLayers() throws {
        #expect(CleanupAdapter.bundled(.off) == nil)
        let medium = try #require(CleanupAdapter.bundled(.medium))
        let deep = try #require(CleanupAdapter.bundled(.deep))
        #expect(medium.directory != deep.directory)
        #expect(medium.baseRevision == deep.baseRevision, "both are loaded into one pinned model")
        #expect(AdapterLayers.shareLayers(try medium.loRAContainer(), try deep.loRAContainer()))
        let configuration = MLXCleaner.Configuration(settings: .defaults)
        #expect(MLXCleaner.compatibleAdapters(in: configuration) == [.medium: medium, .deep: deep])
    }

    @Test func deepsAdapterIsLeftOutWhenTrainedOnAnotherCommit() {
        let medium = CleanupAdapter(baseModel: "m", baseRevision: commit, directory: URL(fileURLWithPath: "/medium"))
        let deep = CleanupAdapter(baseModel: "m", baseRevision: commit, directory: URL(fileURLWithPath: "/deep"))
        let elsewhere = CleanupAdapter(baseModel: "m", baseRevision: String(commit.reversed()), directory: URL(fileURLWithPath: "/deep"))
        func adapters(_ medium: CleanupAdapter?, _ deep: CleanupAdapter?) -> [CleanupRequest.Adapter: CleanupAdapter] {
            MLXCleaner.compatibleAdapters(
                in: MLXCleaner.Configuration(modelID: "m", contextSegments: 3, timeoutSeconds: 1, adapter: medium, deepAdapter: deep)
            )
        }
        #expect(adapters(medium, deep) == [.medium: medium, .deep: deep])
        #expect(adapters(medium, elsewhere) == [.medium: medium])
        #expect(adapters(nil, elsewhere) == [.deep: elsewhere])
        #expect(adapters(nil, nil).isEmpty)
    }

    @Test func deepRunsWithTheSelfCorrectionAdapterWithoutItsOwn() throws {
        let medium = try #require(CleanupAdapter.bundled(.medium)).loRAContainer()
        let deep = try #require(CleanupAdapter.bundled(.deep)).loRAContainer()
        let both = AdapterLayers(adapters: [.medium: medium, .deep: deep])
        #expect(CleanupRequest.Adapter.allCases.map(both.resolved) == [.off, .medium, .deep])
        let mediumOnly = AdapterLayers(adapters: [.medium: medium])
        #expect(CleanupRequest.Adapter.allCases.map(mediumOnly.resolved) == [.off, .medium, .medium])
        let deepOnly = AdapterLayers(adapters: [.deep: deep])
        #expect(CleanupRequest.Adapter.allCases.map(deepOnly.resolved) == [.off, .off, .deep])
    }

    @Test func theAdapterGetsThePromptItWasTrainedOn() throws {
        let adapter = CleanupAdapter(baseModel: "m", baseRevision: commit, directory: URL(fileURLWithPath: "/"))
        let medium = CleanupOptions(level: .medium)
        let configuration = MLXCleaner.Configuration(modelID: "m", contextSegments: 3, timeoutSeconds: 1, adapter: adapter)
        let explicit = MLXCleaner.Configuration(
            modelID: "m", contextSegments: 3, timeoutSeconds: 1, adapter: adapter, promptOverride: Prompt.cleanup
        )
        #expect(configuration.prompts(adapted: true).template(for: medium) == Prompt.adapted)
        #expect(configuration.prompts(adapted: false).template(for: medium) == Prompt.cleanup)
        #expect(explicit.prompts(adapted: true).template(for: medium) == Prompt.cleanup)
    }
}
