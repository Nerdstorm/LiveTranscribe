import Foundation
import HuggingFace
import MLXAudioSTT
import Shared
import Testing
@testable import Transcription

/// The catalog built into the app, and where its models are on disk. Nothing here downloads.
@Suite("Speech model catalog")
struct SpeechModelCatalogTests {
    /// Licences that allow commercial use. A model under any other needs a decision first.
    private static let allowedLicences: Set<String> = ["Apache-2.0", "MIT", "CC-BY-4.0", "CC-BY-SA-4.0"]

    private let catalog = SpeechModelCatalog.bundled

    // MARK: The bundled catalog

    @Test func theDefaultModelComesFirst() throws {
        let first = try #require(catalog.models.first)
        #expect(catalog.model(forSetting: AppSettings.defaults.sttModel) == first)
    }

    @Test func everyModelIsPinnedToACommitOfAKindTheAppRuns() {
        #expect(catalog.models.count >= 2)
        for model in catalog.models {
            #expect(model.mac.revision.count == 40 && model.mac.revision.allSatisfy(\.isHexDigit), "\(model.id)")
            #expect(SpeechModelKind.named(model.mac.kind) != nil, "\(model.id): \(model.mac.kind)")
            #expect(model.mac.bytes > 0, "\(model.id)")
            #expect(Self.allowedLicences.contains(model.licence), "\(model.id): \(model.licence)")
            for text in [model.name, model.summary, model.languages, model.credit] {
                #expect(!text.trimmingCharacters(in: .whitespaces).isEmpty, "\(model.id)")
            }
        }
    }

    @Test func noModelOrRepositoryIsListedTwice() {
        #expect(Set(catalog.models.map(\.id)).count == catalog.models.count)
        #expect(Set(catalog.models.map { $0.mac.repository.rawValue.lowercased() }).count == catalog.models.count)
    }

    /// mlx-audio-swift's Cohere tokenizer knows these codes, and writes English for any other.
    @Test func cohereIsToldOneOfTheLanguagesItKnows() throws {
        let cohere = try #require(catalog.models.first { $0.id == "cohere-transcribe" })
        #expect(cohere.languageChoices.first?.code == "en", "English is the default")
        #expect(cohere.languageChoices.map(\.code).sorted() == ["ar", "de", "el", "en", "es", "fr", "it", "ja", "ko", "nl", "pl", "pt", "vi", "zh"])
        #expect(cohere.languageChoices.allSatisfy { !$0.name.isEmpty })
        for model in catalog.models where model.id != "cohere-transcribe" {
            #expect(model.languageChoices.isEmpty, "\(model.id) finds the language itself")
        }
    }

    @Test func theLanguageToldIsTheSettingsIfTheModelHasItAndElseItsFirst() throws {
        let cohere = try #require(catalog.models.first { $0.id == "cohere-transcribe" })
        #expect(cohere.language(forSetting: "de")?.name == "German")
        #expect(cohere.language(forSetting: nil)?.code == "en")
        #expect(cohere.language(forSetting: "si")?.code == "en", "Sinhala isn't one of its languages")
        let parakeet = try #require(catalog.models.first { $0.id == "parakeet-tdt-0.6b-v3" })
        #expect(parakeet.language(forSetting: "de") == nil)
    }

    /// The transcriber tells Cohere the language at each transcription, and leaves the others'
    /// parameters as they are.
    @Test func onlyAModelThatIsToldALanguageGetsTheSettings() throws {
        let cohere = try #require(catalog.models.first { $0.id == "cohere-transcribe" })
        let parakeet = try #require(catalog.models.first { $0.id == "parakeet-tdt-0.6b-v3" })
        let english = STTGenerateParameters(maxTokens: 512, temperature: 0.2, language: "en")
        let told = MLXTranscriber.parameters(english, for: cohere, language: "de")
        #expect(told.language == "de")
        #expect(told.maxTokens == 512 && told.temperature == 0.2, "the rest are kept")
        #expect(MLXTranscriber.parameters(english, for: cohere, language: "si").language == "en")
        #expect(MLXTranscriber.parameters(STTGenerateParameters(), for: parakeet, language: "de").language == nil)
        #expect(MLXTranscriber.parameters(english, for: nil, language: "de").language == "en", "a model outside the catalog")
    }

    /// Parakeet's config.json names no kind, so the app reads it from the repository's name.
    @Test func aKindItsConfigDoesntNameIsInTheRepositorysName() throws {
        for model in catalog.models where model.mac.kind == "parakeet" {
            let folder = try SnapshotFolder(config: [:])
            defer { folder.remove() }
            #expect(try SpeechModelKind.of(folder: folder.url, name: model.mac.repository.name).modelType == "parakeet")
        }
    }

    // MARK: Reading a catalog

    @Test func onlyModelsWithAMacDownloadAreKept() throws {
        let catalog = try SpeechModelCatalog(json: Self.json(models: [
            Self.entry(id: "both", mac: true),
            Self.entry(id: "linux-only", mac: false),
        ]))
        #expect(catalog.models.map(\.id) == ["both"])
    }

    @Test func aModelsLanguageChoicesAreReadAndOptional() throws {
        var told = Self.entry(id: "told", mac: true)
        told["language_choices"] = [["code": "en", "name": "English"], ["code": "de", "name": "German"]]
        let catalog = try SpeechModelCatalog(json: Self.json(models: [told, Self.entry(id: "finds", mac: true)]))
        #expect(catalog.models[0].languageChoices.map(\.code) == ["en", "de"])
        #expect(catalog.models[1].languageChoices.isEmpty)
    }

    @Test func anotherFormatIsRefused() {
        #expect(throws: SpeechModelCatalog.LoadError.unsupportedFormat(2)) {
            try SpeechModelCatalog(json: Self.json(format: 2, models: []))
        }
    }

    @Test func aSettingFindsItsModelIgnoringCaseAndSpaces() throws {
        let catalog = try SpeechModelCatalog(json: Self.json(models: [Self.entry(id: "a", mac: true)]))
        #expect(catalog.model(forSetting: "  Owner/A-Model \n")?.id == "a")
        #expect(catalog.model(forSetting: "owner/another") == nil)
        #expect(catalog.model(forSetting: "/Users/me/owner/a-model") == nil)
    }

    // MARK: Where the models are

    @Test func aModelIsDownloadedWhenItsPinnedSnapshotHasItsConfigAndWeights() throws {
        let cache = try TemporaryCache()
        defer { cache.remove() }
        let model = Self.model()
        let downloads = SpeechModelDownloads(cache: cache.hubCache)
        #expect(downloads.folder(for: model) == nil)

        let snapshot = try cache.snapshot(of: model, files: ["config.json": Self.config])
        #expect(downloads.folder(for: model) == nil, "no weights yet")

        try cache.addBlob(named: "model.safetensors", to: snapshot, contents: Data([1]))
        #expect(downloads.folder(for: model)?.path == snapshot.path)
    }

    /// A snapshot's files link to the cache's blobs: a link to a blob that isn't there is missing.
    @Test func aWeightLinkToAMissingBlobIsNotDownloaded() throws {
        let cache = try TemporaryCache()
        defer { cache.remove() }
        let model = Self.model()
        let snapshot = try cache.snapshot(of: model, files: ["config.json": Self.config])
        try cache.addBlob(named: "model.safetensors", to: snapshot, contents: Data([1]))
        try FileManager.default.removeItem(at: cache.blobs(of: model))
        #expect(SpeechModelDownloads(cache: cache.hubCache).folder(for: model) == nil)
    }

    @Test func everyWeightFileTheIndexListsMustBeThere() throws {
        let cache = try TemporaryCache()
        defer { cache.remove() }
        let model = Self.model()
        let index = ["weight_map": ["a.weight": "model-1.safetensors", "b.weight": "model-2.safetensors"]]
        let snapshot = try cache.snapshot(of: model, files: [
            "config.json": Self.config,
            "model.safetensors.index.json": try JSONSerialization.data(withJSONObject: index),
        ])
        try cache.addBlob(named: "model-1.safetensors", to: snapshot, contents: Data([1]))
        let downloads = SpeechModelDownloads(cache: cache.hubCache)
        #expect(downloads.folder(for: model) == nil, "one shard is missing")

        try cache.addBlob(named: "model-2.safetensors", to: snapshot, contents: Data([2]))
        #expect(downloads.folder(for: model)?.path == snapshot.path)
    }

    @Test func removingAModelRemovesEveryCopyOfIt() throws {
        let cache = try TemporaryCache()
        defer { cache.remove() }
        let model = Self.model()
        let snapshot = try cache.snapshot(of: model, files: ["config.json": Self.config])
        try cache.addBlob(named: "model.safetensors", to: snapshot, contents: Data([1]))
        let olderCopy = try cache.olderCopy(of: model)
        let downloads = SpeechModelDownloads(cache: cache.hubCache)
        #expect(downloads.olderCopy(of: model)?.path == olderCopy.path)
        #expect(downloads.hasFiles(of: model))

        try downloads.remove(model)

        #expect(!downloads.hasFiles(of: model))
        #expect(!FileManager.default.fileExists(atPath: cache.hubCache.repoDirectory(repo: model.mac.repository, kind: .model).path))
        #expect(!FileManager.default.fileExists(atPath: olderCopy.path))
        try downloads.remove(model)
    }

    // MARK: Helpers

    private static let config = Data(#"{"model_type": "qwen3_asr"}"#.utf8)

    private static func model(repository: Repo.ID = "owner/a-model") -> SpeechModelCatalog.Model {
        SpeechModelCatalog.Model(
            id: "a-model", name: "A Model", summary: "For tests.", languages: "English", licence: "MIT", credit: "Nobody",
            languageChoices: [],
            mac: .init(repository: repository, revision: String(repeating: "a", count: 40), bytes: 1, kind: "qwen3_asr")
        )
    }

    private static func entry(id: String, mac: Bool) -> [String: Any] {
        var entry: [String: Any] = [
            "id": id, "name": id, "summary": "s", "languages": "l", "licence": "MIT", "credit": "c",
            "linuxWindows": ["archive": "https://example.com/\(id).tar.bz2"],
        ]
        if mac {
            entry["mac"] = ["repository": "owner/A-Model", "revision": String(repeating: "b", count: 40), "bytes": 1, "kind": "whisper"]
        }
        return entry
    }

    private static func json(format: Int = 1, models: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["format": format, "models": models])
    }
}

/// A Hugging Face cache in a temporary folder, laid out as swift-huggingface lays it out.
private struct TemporaryCache {
    let root: URL
    let hubCache: HubCache

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("speech-model-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        hubCache = HubCache(cacheDirectory: root)
    }

    /// The model's snapshot folder at its pinned commit, with `files` written into it.
    func snapshot(of model: SpeechModelCatalog.Model, files: [String: Data]) throws -> URL {
        let snapshot = try hubCache.snapshotPath(repo: model.mac.repository, kind: .model, commitHash: model.mac.revision)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        for (name, contents) in files {
            try contents.write(to: snapshot.appendingPathComponent(name))
        }
        return snapshot
    }

    func blobs(of model: SpeechModelCatalog.Model) -> URL {
        hubCache.blobsDirectory(repo: model.mac.repository, kind: .model)
    }

    /// Writes a blob and links the snapshot's `name` to it, as a download does.
    func addBlob(named name: String, to snapshot: URL, contents: Data) throws {
        let blobs = snapshot.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("blobs")
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        let blob = blobs.appendingPathComponent(UUID().uuidString)
        try contents.write(to: blob)
        try FileManager.default.createSymbolicLink(
            atPath: snapshot.appendingPathComponent(name).path,
            withDestinationPath: "../../blobs/\(blob.lastPathComponent)"
        )
    }

    /// A copy of the model where mlx-audio-swift keeps one.
    func olderCopy(of model: SpeechModelCatalog.Model) throws -> URL {
        let folder = root.appendingPathComponent("mlx-audio")
            .appendingPathComponent(model.mac.repository.rawValue.replacingOccurrences(of: "/", with: "_"))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"model_type": "qwen3_asr"}"#.utf8).write(to: folder.appendingPathComponent("config.json"))
        try Data([1]).write(to: folder.appendingPathComponent("model.safetensors"))
        return folder
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

/// A folder with a config.json and weights, as a model's.
private struct SnapshotFolder {
    let url: URL

    init(config: [String: Any]) throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("speech-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: config).write(to: url.appendingPathComponent("config.json"))
        try Data([0]).write(to: url.appendingPathComponent("model.safetensors"))
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
