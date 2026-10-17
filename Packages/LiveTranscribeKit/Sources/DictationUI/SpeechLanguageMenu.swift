import Shared
import Transcription

/// The Language setting as a menu offers it for one speech model, in the menu bar and on the
/// model's row in Settings › Models: Automatic first, then the languages the model can be told.
///
/// The setting is one for every model (``AppSettingsKey/sttLanguage``), so a language the model
/// in use doesn't have shows as Automatic, and is kept for a model that has it.
struct SpeechLanguageMenu: Equatable {
    /// Automatic's tag in a picker: the setting is absent.
    static let automatic = ""

    /// What Automatic does: the model finds the language, or, for one that can't, writes the one
    /// in brackets, "Automatic (English)".
    let automaticTitle: String
    /// The languages the model can be told, in the catalog's order; empty for a model that
    /// can't be told one, or one outside the catalog, whose menu is Automatic alone.
    let choices: [SpeechModelCatalog.LanguageChoice]

    init(model: SpeechModelCatalog.Model?) {
        choices = model?.languageChoices ?? []
        automaticTitle = model?.automaticChoice.map { "Automatic (\($0.name))" } ?? "Automatic"
    }

    /// Whether there is anything to choose.
    var canChoose: Bool { !choices.isEmpty }

    /// The picker's tag for the setting: its code if the model has it, and otherwise Automatic's.
    func tag(forSetting setting: String?) -> String {
        choices.contains { $0.code == setting } ? setting ?? Self.automatic : Self.automatic
    }

    /// The setting for a tag the picker gives: `nil` for Automatic.
    static func setting(forTag tag: String) -> String? {
        tag == automatic ? nil : tag
    }
}
