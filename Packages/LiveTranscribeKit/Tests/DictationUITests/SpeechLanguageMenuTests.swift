@testable import DictationUI
import Testing
import Transcription

/// The Language menu, in the menu bar and on a model's row in Settings › Models.
@Suite("Speech language menu")
struct SpeechLanguageMenuTests {
    private let catalog = SpeechModelCatalog.bundled

    private func menu(_ id: String) throws -> SpeechLanguageMenu {
        SpeechLanguageMenu(model: try #require(catalog.models.first { $0.id == id }))
    }

    @Test func automaticComesFirstAndOnlyTheModelsLanguagesFollow() throws {
        let qwen = try menu("qwen3-asr-0.6b-sinhala")
        #expect(qwen.automaticTitle == "Automatic")
        #expect(qwen.choices.first?.name == "English")
        #expect(qwen.choices.contains { $0.code == "si" })
        #expect(try !menu("qwen3-asr-0.6b").choices.contains { $0.code == "si" }, "only the fine-tune knows Sinhala")
    }

    @Test func automaticSaysWhatAModelThatCantFindTheLanguageWrites() throws {
        #expect(try menu("cohere-transcribe").automaticTitle == "Automatic (English)")
    }

    @Test func aModelThatCantBeToldALanguageHasAutomaticAlone() throws {
        let parakeet = try menu("parakeet-tdt-0.6b-v3")
        #expect(!parakeet.canChoose)
        #expect(parakeet.tag(forSetting: "de") == SpeechLanguageMenu.automatic)
        #expect(!SpeechLanguageMenu(model: nil).canChoose, "a model outside the catalog")
    }

    /// The setting is one for every model: a language this one lacks shows as Automatic.
    @Test func theSettingShowsAsItsLanguageOrAutomatic() throws {
        let qwen = try menu("qwen3-asr-0.6b")
        #expect(qwen.tag(forSetting: "en") == "en")
        #expect(qwen.tag(forSetting: nil) == SpeechLanguageMenu.automatic)
        #expect(qwen.tag(forSetting: "ca") == SpeechLanguageMenu.automatic, "Catalan is Whisper's")
        #expect(SpeechLanguageMenu.setting(forTag: SpeechLanguageMenu.automatic) == nil)
        #expect(SpeechLanguageMenu.setting(forTag: "en") == "en")
    }
}
