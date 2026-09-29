import Foundation
import HuggingFace
import Shared

/// The speech-to-text models Settings › Models offers to download, from `speech-models.json`.
///
/// The catalog is built into the app and never fetched, and each model is pinned to one commit
/// of its Hugging Face repository: every copy of a release downloads the files it was tested
/// with, and moving a pin is a change like any other. The Linux and Windows app reads the same
/// file, so a model is named, described and credited alike everywhere; each platform has its own
/// download in it, and a model without the Mac's is left out here. A model that is told which
/// language to write, where others find it, lists the languages it can be told
/// (`language_choices`), for the Language setting.
public struct SpeechModelCatalog: Sendable {
    /// One model: what Settings shows about it, and where the Mac downloads it from.
    public struct Model: Decodable, Identifiable, Equatable, Sendable {
        /// Stays the same across releases and platforms, such as `qwen3-asr-0.6b-sinhala`.
        public let id: String
        public let name: String
        /// What to pick it for, in a sentence.
        public let summary: String
        public let languages: String
        /// An SPDX identifier, such as `Apache-2.0`.
        public let licence: String
        /// Who made it, credited as its licence asks.
        public let credit: String
        /// The languages it can be told to write, its default first; empty for a model that
        /// finds the language itself.
        public let languageChoices: [LanguageChoice]
        /// The Mac's download.
        public let mac: Download

        /// The language to tell it to write, for the Language setting (a code): the setting's,
        /// if it's one of the model's, and otherwise its first. `nil` for a model that isn't
        /// told one.
        public func language(forSetting setting: String?) -> LanguageChoice? {
            languageChoices.first { $0.code == setting } ?? languageChoices.first
        }
    }

    /// A language a model can be told to write.
    public struct LanguageChoice: Decodable, Hashable, Identifiable, Sendable {
        /// Its ISO 639-1 code, as the model is told it: `en`, `de`.
        public let code: String
        /// Its name in English, as Settings shows it.
        public let name: String

        public var id: String { code }
    }

    /// A model's files for the Mac: a Hugging Face repository at one commit.
    public struct Download: Decodable, Equatable, Sendable {
        public let repository: Repo.ID
        /// The commit, 40 hex digits.
        public let revision: String
        /// The size of the files the Mac downloads.
        public let bytes: Int64
        /// The ``SpeechModelKind`` the model is (its `model_type`).
        public let kind: String
    }

    public enum LoadError: LocalizedError, Equatable {
        case missing
        case unreadable(String)
        case unsupportedFormat(Int)

        public var errorDescription: String? {
            switch self {
            case .missing: "The speech model catalog is missing from the app."
            case .unreadable(let detail): "The speech model catalog can't be read: \(detail)"
            case .unsupportedFormat(let format): "The speech model catalog is in format \(format), which this version can't read."
            }
        }
    }

    /// The version of `speech-models.json` this build reads. A change older builds would misread
    /// needs a new number; a new field they would ignore doesn't.
    static let format = 1

    public let models: [Model]

    init(models: [Model]) {
        self.models = models
    }

    /// Reads a catalog, keeping the models the Mac can download.
    public init(json: Data) throws(LoadError) {
        let file: File
        do {
            file = try JSONDecoder().decode(File.self, from: json)
        } catch {
            throw .unreadable(String(describing: error))
        }
        guard file.format == Self.format else { throw .unsupportedFormat(file.format) }
        models = file.models.compactMap(\.model)
    }

    /// The catalog built into the app. If it can't be read, which the tests rule out, Settings
    /// offers no models and the Speech-to-text setting still takes any repository or folder.
    public static let bundled: SpeechModelCatalog = {
        do {
            guard let url = Bundle.module.url(forResource: "speech-models", withExtension: "json") else {
                throw LoadError.missing
            }
            return try SpeechModelCatalog(json: Data(contentsOf: url))
        } catch {
            Log.transcription.error("No speech model catalog: \(error.localizedDescription, privacy: .public)")
            return SpeechModelCatalog(models: [])
        }
    }()

    /// The model that the Speech-to-text setting names by its repository, ignoring case as
    /// Hugging Face does.
    public func model(forSetting setting: String) -> Model? {
        let text = setting.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return models.first { $0.mac.repository.rawValue.lowercased() == text }
    }

    /// The file's layout: every platform's models, of which this build keeps the Mac's.
    private struct File: Decodable {
        let format: Int
        let models: [Entry]
    }

    private struct Entry: Decodable {
        let id: String
        let name: String
        let summary: String
        let languages: String
        let licence: String
        let credit: String
        let languageChoices: [LanguageChoice]?
        let mac: Download?

        private enum CodingKeys: String, CodingKey {
            case id, name, summary, languages, licence, credit, mac
            case languageChoices = "language_choices"
        }

        var model: Model? {
            mac.map {
                Model(
                    id: id, name: name, summary: summary, languages: languages, licence: licence, credit: credit,
                    languageChoices: languageChoices ?? [], mac: $0
                )
            }
        }
    }
}
