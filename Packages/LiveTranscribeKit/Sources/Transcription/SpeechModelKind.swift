import Foundation
import MLXAudioSTT

/// A kind of speech-to-text model the app can run, found by the `model_type` in the model's
/// config.json, and how to load one from its folder.
///
/// Every kind in ``all`` is implemented by mlx-audio-swift, so switching between them (Qwen3-ASR,
/// Parakeet, Whisper and the rest) is only a matter of the Speech-to-text setting. A model the app
/// implemented itself would be one more entry, a type conforming to `STTGenerationModel`.
struct SpeechModelKind: Sendable {
    /// config.json's `model_type`, as mlx-audio-swift names it.
    let modelType: String
    /// Other names that configs and repository names use for it.
    let aliases: [String]
    /// Files the model needs besides config.json, the weights, and other JSON and text files (the
    /// files mlx-audio-swift downloads for every model).
    let extraFiles: [String]
    /// Loads a model of this kind from its folder.
    let load: @Sendable (URL) async throws -> any STTGenerationModel

    private init(
        _ modelType: String,
        aliases: [String] = [],
        extraFiles: [String] = [],
        load: @escaping @Sendable (URL) async throws -> any STTGenerationModel
    ) {
        self.modelType = modelType
        self.aliases = aliases
        self.extraFiles = extraFiles
        self.load = load
    }

    /// mlx-audio-swift's speech-to-text models, with the names and aliases its `STT.loadModel`
    /// accepts and the files each one's `fromPretrained` downloads. When an mlx-audio-swift update
    /// adds or renames a model, change this list with it.
    static let all: [SpeechModelKind] = [
        SpeechModelKind("qwen3_asr") { try await Qwen3ASRModel.fromModelDirectory($0) },
        SpeechModelKind("parakeet") { try ParakeetModel.fromDirectory($0) },
        SpeechModelKind("whisper", extraFiles: ["*.model"]) { try await WhisperModel.fromDirectory($0) },
        SpeechModelKind("canary", extraFiles: ["*.model"]) { try await CanaryModel.fromModelDirectory($0) },
        SpeechModelKind("cohere_asr", aliases: ["cohere"], extraFiles: ["*.model"]) {
            try CohereTranscribeModel.fromDirectory($0)
        },
        SpeechModelKind("fireredasr2", aliases: ["firered", "fire_red"]) { try FireRedASR2Model.fromDirectory($0) },
        SpeechModelKind("glmasr", aliases: ["glm"]) { try await GLMASRModel.fromModelDirectory($0) },
        SpeechModelKind("granite_speech") { try await GraniteSpeechModel.fromModelDirectory($0) },
        SpeechModelKind("lasr_ctc", aliases: ["lasr"]) { try LasrCTCModel.fromModelDirectory($0) },
        SpeechModelKind("moonshine", extraFiles: ["tokenizer.*"]) { try await MoonshineModel.fromModelDirectory($0) },
        SpeechModelKind("moss_transcribe_diarize") { try await MossTranscribeDiarizeModel.fromModelDirectory($0) },
        SpeechModelKind("nemotron_asr", aliases: ["nemotron"]) { try NemotronASRModel.fromDirectory($0) },
        SpeechModelKind("sensevoice", extraFiles: ["*.mvn", "*.model", "tokenizer*"]) {
            try SenseVoiceModel.fromDirectory($0)
        },
        SpeechModelKind("voxtral_realtime", aliases: ["voxtral"]) { try VoxtralRealtimeModel.fromDirectory($0) },
        SpeechModelKind("wav2vec2", aliases: ["wav2vec", "mms"]) { try Wav2Vec2CTCModel.fromModelDirectory($0) },
    ]

    /// What a download fetches besides mlx-audio-swift's usual files. The kind is known only once
    /// config.json is there, so a download fetches every kind's extra files; they are small.
    static let downloadPatterns: [String] = {
        var seen = Set<String>()
        return all.flatMap(\.extraFiles).filter { seen.insert($0).inserted }
    }()

    /// The kind whose `model_type` or alias is `name`, ignoring case.
    static func named(_ name: String) -> SpeechModelKind? {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return all.first { $0.modelType == key || $0.aliases.contains(key) }
    }

    /// The kind of the model in `folder`, which must hold config.json and the .safetensors weights.
    ///
    /// The kind comes from config.json's `model_type` (or `architecture` or `model_version`, which
    /// some models use instead). A config without any of them, such as Parakeet's, is named by the
    /// first word of the model's name that names a kind, as mlx-audio-swift reads a repository
    /// name: parakeet-tdt-0.6b-v3, and mlx-audio-swift's folder for it,
    /// mlx-community_parakeet-tdt-0.6b-v3, are parakeet models.
    static func of(folder: URL, name: String) throws(TranscriptionError) -> SpeechModelKind {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("config.json")),
              let config = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              hasWeights(folder)
        else { throw .modelNotFound(folder.path) }

        if let declared = ["model_type", "architecture", "model_version"].lazy.compactMap({ config[$0] as? String }).first {
            guard let kind = named(declared) else { throw .unsupportedModel(name: name, modelType: declared) }
            return kind
        }
        let words = name.split { "-_. ".contains($0) }
        if let kind = words.lazy.compactMap({ named(String($0)) }).first {
            return kind
        }
        throw .unsupportedModel(name: name, modelType: nil)
    }

    /// Whether the folder has its weights: every file that model.safetensors.index.json lists, or
    /// without an index, a .safetensors file, each with something in it, as mlx-audio-swift
    /// requires of a downloaded model.
    ///
    /// Files in a Hugging Face snapshot are links to the cache's blobs, so a link is measured by
    /// what it points to, and a link to a blob that isn't there counts as missing.
    private static func hasWeights(_ folder: URL) -> Bool {
        if let data = try? Data(contentsOf: folder.appendingPathComponent("model.safetensors.index.json")) {
            guard let index = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let weightMap = index["weight_map"] as? [String: String], !weightMap.isEmpty
            else { return false }
            return Set(weightMap.values).allSatisfy { hasContent(folder.appendingPathComponent($0)) }
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.contains { $0.pathExtension == "safetensors" && hasContent($0) }
    }

    /// stat(2) follows links, and fails for a link to nothing.
    private static func hasContent(_ file: URL) -> Bool {
        var info = stat()
        return stat(file.path, &info) == 0 && info.st_size > 0
    }
}
