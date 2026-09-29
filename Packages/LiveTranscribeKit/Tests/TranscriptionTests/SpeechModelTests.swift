import Foundation
import HuggingFace
import os
import Shared
import Testing
@testable import Transcription

/// How the Speech-to-text setting becomes a model: a repository or a folder, then the kind of
/// model its config.json names. Nothing here downloads or loads a real model.
@Suite("Speech models")
struct SpeechModelTests {
    // MARK: The setting

    @Test func aRepositoryIDIsARepository() throws {
        #expect(try SpeechModelLocation(setting: "Nerdstorm/Qwen3-ASR-0.6B-Sinhala-8bit")
            == .repository(Repo.ID(namespace: "Nerdstorm", name: "Qwen3-ASR-0.6B-Sinhala-8bit")))
        #expect(try SpeechModelLocation(setting: "  mlx-community/parakeet-tdt-0.6b-v3\n")
            == .repository(Repo.ID(namespace: "mlx-community", name: "parakeet-tdt-0.6b-v3")))
    }

    @Test func aPathIsAFolder() throws {
        #expect(try SpeechModelLocation(setting: "/Users/me/Models/qwen")
            == .folder(URL(fileURLWithPath: "/Users/me/Models/qwen", isDirectory: true)))
        #expect(try SpeechModelLocation(setting: "~/Models/qwen/")
            == .folder(URL(fileURLWithPath: NSHomeDirectory() + "/Models/qwen", isDirectory: true)))
    }

    @Test(arguments: ["", "   ", "qwen3-asr", "Nerdstorm/", "a b/c", "org/name/extra"])
    func anythingElseIsInvalid(_ setting: String) {
        #expect(throws: TranscriptionError.invalidModelID(setting)) { try SpeechModelLocation(setting: setting) }
    }

    @Test func theNameIsTheRepositorysOrTheFolders() throws {
        #expect(try SpeechModelLocation(setting: "mlx-community/parakeet-tdt-0.6b-v3").name == "parakeet-tdt-0.6b-v3")
        #expect(try SpeechModelLocation(setting: "/tmp/qwen-sinhala").name == "qwen-sinhala")
    }

    /// Logs name a folder without its path, which holds the user's name.
    @Test func logsNameAFolderWithoutItsPath() throws {
        #expect(try SpeechModelLocation(setting: "Nerdstorm/Qwen3-ASR-0.6B-Sinhala-8bit").description
            == "Nerdstorm/Qwen3-ASR-0.6B-Sinhala-8bit")
        #expect(try SpeechModelLocation(setting: "/Users/someone/Models/qwen-sinhala").description == "folder qwen-sinhala")
    }

    // MARK: Kinds

    @Test func everyNameFindsItsKindAndNoNameIsUsedTwice() {
        var names = Set<String>()
        for kind in SpeechModelKind.all {
            for name in [kind.modelType] + kind.aliases {
                #expect(names.insert(name).inserted, "\(name) names two kinds")
                #expect(SpeechModelKind.named(name)?.modelType == kind.modelType)
                #expect(SpeechModelKind.named(" \(name.uppercased()) ")?.modelType == kind.modelType)
            }
        }
        #expect(SpeechModelKind.named("niagara") == nil)
    }

    @Test func theModelsTheAppHasShippedAreRunnable() {
        for modelType in ["qwen3_asr", "parakeet"] {
            #expect(SpeechModelKind.named(modelType) != nil, "\(modelType)")
        }
    }

    @Test func aDownloadFetchesEveryKindsExtraFilesOnce() {
        let patterns = SpeechModelKind.downloadPatterns
        #expect(Set(patterns) == Set(SpeechModelKind.all.flatMap(\.extraFiles)))
        #expect(patterns.count == Set(patterns).count)
    }

    // MARK: A model's folder

    @Test func configsModelTypeNamesTheKind() throws {
        let folder = try ModelFolder(config: ["model_type": "qwen3_asr", "architecture": "something_else"])
        defer { folder.remove() }
        #expect(try SpeechModelKind.of(folder: folder.url, name: "anything").modelType == "qwen3_asr")
    }

    @Test func architectureOrModelVersionNameTheKindWithoutAModelType() throws {
        let byArchitecture = try ModelFolder(config: ["architecture": "whisper"])
        defer { byArchitecture.remove() }
        #expect(try SpeechModelKind.of(folder: byArchitecture.url, name: "x").modelType == "whisper")
        let byVersion = try ModelFolder(config: ["model_version": "Parakeet"])
        defer { byVersion.remove() }
        #expect(try SpeechModelKind.of(folder: byVersion.url, name: "x").modelType == "parakeet")
    }

    /// Parakeet's config.json names no kind, so its name does, as mlx-audio-swift reads it.
    @Test func aConfigThatNamesNoKindIsReadFromTheModelsName() throws {
        let folder = try ModelFolder(config: ["encoder": ["d_model": 1024]])
        defer { folder.remove() }
        #expect(try SpeechModelKind.of(folder: folder.url, name: "parakeet-tdt-0.6b-v3").modelType == "parakeet")
        #expect(try SpeechModelKind.of(folder: folder.url, name: "Parakeet-TDT").modelType == "parakeet")
        // mlx-audio-swift's folder for a repository starts with the owner.
        #expect(try SpeechModelKind.of(folder: folder.url, name: "mlx-community_parakeet-tdt-0.6b-v3").modelType == "parakeet")
    }

    @Test func aKindTheAppCantRunIsReported() throws {
        let declared = try ModelFolder(config: ["model_type": "niagara"])
        defer { declared.remove() }
        #expect(throws: TranscriptionError.unsupportedModel(name: "niagara-sinhala", modelType: "niagara")) {
            try SpeechModelKind.of(folder: declared.url, name: "niagara-sinhala")
        }
        let unnamed = try ModelFolder(config: [:])
        defer { unnamed.remove() }
        #expect(throws: TranscriptionError.unsupportedModel(name: "my-model", modelType: nil)) {
            try SpeechModelKind.of(folder: unnamed.url, name: "my-model")
        }
    }

    @Test func aFolderWithoutAModelIsReported() throws {
        let noConfig = try ModelFolder(config: nil)
        let noWeights = try ModelFolder(config: ["model_type": "qwen3_asr"], weights: nil)
        let emptyWeights = try ModelFolder(config: ["model_type": "qwen3_asr"], weights: Data())
        let badConfig = try ModelFolder(config: nil)
        let folders = [noConfig, noWeights, emptyWeights, badConfig]
        defer { folders.forEach { $0.remove() } }
        try Data("{ not json".utf8).write(to: badConfig.url.appendingPathComponent("config.json"))
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("no-such-model-\(UUID().uuidString)")
        for folder in folders.map(\.url) + [missing] {
            #expect(throws: TranscriptionError.modelNotFound(folder.path)) {
                try SpeechModelKind.of(folder: folder, name: "qwen")
            }
        }
    }

    @Test func errorsSayWhatTheAppCanRun() {
        let unsupported = TranscriptionError.unsupportedModel(name: "niagara-sinhala", modelType: "niagara").errorDescription ?? ""
        #expect(unsupported.contains("niagara-sinhala is a niagara model"))
        #expect(unsupported.contains("qwen3_asr") && unsupported.contains("parakeet") && unsupported.contains("whisper"))
        let unnamed = TranscriptionError.unsupportedModel(name: "my-model", modelType: nil).errorDescription ?? ""
        #expect(unnamed.contains("model_type"))
        #expect((TranscriptionError.modelNotFound("/tmp/x").errorDescription ?? "").contains("config.json"))
    }

    // MARK: The transcriber

    /// A folder is loaded where it is: no download stage, and a model the app can't run fails
    /// before anything is loaded.
    @Test func aFolderIsNotDownloadedAndAnUnrunnableOneFailsToLoad() async throws {
        let folder = try ModelFolder(config: ["model_type": "niagara"])
        defer { folder.remove() }
        let stages = OSAllocatedUnfairLock(initialState: [ModelLoadProgress.Stage]())
        let transcriber = MLXTranscriber(modelID: folder.url.path)
        await #expect(throws: TranscriptionError.unsupportedModel(name: folder.url.lastPathComponent, modelType: "niagara")) {
            try await transcriber.load { progress in stages.withLock { $0.append(progress.stage) } }
        }
        #expect(stages.withLock { $0 } == [.loading])
    }

    @Test func anInvalidSettingFailsToLoad() async {
        let transcriber = MLXTranscriber(modelID: "not a model")
        await #expect(throws: TranscriptionError.invalidModelID("not a model")) {
            try await transcriber.load { _ in }
        }
    }
}

/// A temporary model folder: config.json (if any) and a model.safetensors (if any).
private struct ModelFolder {
    let url: URL

    init(config: [String: Any]?, weights: Data? = Data([0])) throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("speech-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        if let config {
            try JSONSerialization.data(withJSONObject: config).write(to: url.appendingPathComponent("config.json"))
        }
        if let weights {
            try weights.write(to: url.appendingPathComponent("model.safetensors"))
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
