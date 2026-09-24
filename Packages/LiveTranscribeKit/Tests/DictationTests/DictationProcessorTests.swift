import Cleanup
@testable import Dictation
import Foundation
import Shared
import Snippets
import Testing
import Vocabulary

@Suite("DictationProcessor")
struct DictationProcessorTests {
    private let calendar = Snippet(trigger: "my calendar link", expansion: "https://cal.example.com/me")
    private let nerdstorm = VocabularyEntry(term: "Nerdstorm", spokenVariants: ["nerd storm"])

    private func configuration(
        _ level: CleanupLevel,
        multiline: Bool = false,
        snippets: [Snippet]? = nil
    ) -> DictationProcessor.Configuration {
        .init(
            level: level,
            snippets: snippets ?? [calendar],
            vocabulary: [nerdstorm],
            vocabularyPromptLimit: 50,
            vocabularySimilarityThreshold: 0.8,
            multiline: multiline
        )
    }

    private func finish(_ transcript: String, _ configuration: DictationProcessor.Configuration, cleaner: (any Cleaner)?) async -> DictationProcessor.Output {
        await DictationProcessor.finish(transcript: transcript, transcriptionMs: 40, configuration: configuration, cleaner: cleaner)
    }

    /// Capitalises and adds a full stop, like a well-behaved model.
    private static func tidy(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst() + "."
    }

    @Test func levelNoneAppliesSnippetsAndVocabularyWithoutTheModel() async {
        let cleaner = ScriptedCleaner { _ in
            Issue.record("the model should not run")
            return ""
        }
        let output = await finish("um send my calendar link to nerd storm", configuration(.none), cleaner: cleaner)
        #expect(output.text == "um send https://cal.example.com/me to Nerdstorm")
        #expect(output.rawTranscript == "um send my calendar link to nerd storm")
        #expect(output.uncleanedText == output.text)
        #expect(!output.fellBack)
    }

    @Test func mediumHidesSnippetsFromTheModelAndExpandsThemAfter() async {
        let cleaner = ScriptedCleaner(reply: Self.tidy)
        let output = await finish("um send my calendar link to nerd storm", configuration(.medium), cleaner: cleaner)

        let request = await cleaner.requests.first
        #expect(request?.text == "send S1 to Nerdstorm", "fillers, snippets and vocabulary are handled before the model")
        #expect(request?.options.placeholders == ["⟦S1⟧"])
        #expect(request?.options.vocabulary == ["Nerdstorm"])
        #expect(output.text == "Send https://cal.example.com/me to Nerdstorm.")
        #expect(output.uncleanedText == "um send https://cal.example.com/me to Nerdstorm")
        #expect(!output.fellBack)
    }

    @Test func aDamagedPlaceholderFallsBackWithSnippetsStillExpanded() async {
        let cleaner = ScriptedCleaner { text in Self.tidy(text.replacingOccurrences(of: "S1", with: "S 1")) }
        let output = await finish("um send my calendar link to nerd storm", configuration(.medium), cleaner: cleaner)
        #expect(output.fellBack)
        #expect(output.fallbackReason == "changed a placeholder")
        #expect(output.text == "send https://cal.example.com/me to Nerdstorm")
    }

    @Test func spokenListsBecomeNumberedLinesOnlyInMultilineFields() async {
        let transcript = "we need three things: first, milk; second, eggs; and third, bread."
        let cleaner = ScriptedCleaner { $0.prefix(1).uppercased() + $0.dropFirst() }
        let multiline = await finish(transcript, configuration(.medium, multiline: true), cleaner: cleaner)
        #expect(multiline.text == "We need three things:\n1. Milk\n2. Eggs\n3. Bread")
        let singleLine = await finish(transcript, configuration(.medium, multiline: false), cleaner: cleaner)
        #expect(singleLine.text == "We need three things: first, milk; second, eggs; and third, bread.")
        let light = await finish(transcript, configuration(.light, multiline: true), cleaner: cleaner)
        #expect(!light.text.contains("\n"), "Light keeps the words as spoken")
    }

    // MARK: - Spoken commands and layout

    @Test func emojiIsHiddenFromTheModelAndWrittenAfter() async {
        let cleaner = ScriptedCleaner(reply: Self.tidy)
        let output = await finish("hi emoji fireworks", configuration(.medium), cleaner: cleaner)
        let request = await cleaner.requests.first
        #expect(request?.text == "hi S1", "the model sees a word for the placeholder")
        #expect(request?.options.placeholders == ["⟦S1⟧"])
        #expect(output.text == "Hi \u{1F386}.")
        #expect(output.uncleanedText == "hi \u{1F386}")
    }

    /// The model punctuates a placeholder's word like a name; an emoji takes no commas the
    /// speaker did not say.
    @Test func commasTheModelPutsAroundAnEmojiGo() async {
        let cleaner = ScriptedCleaner { _ in "Great job, S1, see you tomorrow." }
        let output = await finish("great job emoji party popper see you tomorrow", configuration(.medium), cleaner: cleaner)
        #expect(output.text == "Great job \u{1F389} see you tomorrow.")
    }

    @Test func aDictatedCommaNextToAnEmojiStays() async {
        let cleaner = ScriptedCleaner { _ in "Great job, S1." }
        let output = await finish("great job comma emoji party popper", configuration(.medium), cleaner: cleaner)
        #expect(output.text == "Great job, \u{1F389}.")
    }

    @Test func commasAroundOtherPlaceholdersStay() async {
        let name = Snippet(trigger: "my name", expansion: "Jordan Lee")
        let cleaner = ScriptedCleaner { _ in "Thanks, S1." }
        let output = await finish("thanks my name", configuration(.medium, snippets: [name]), cleaner: cleaner)
        #expect(output.text == "Thanks, Jordan Lee.")
    }

    @Test func commandsApplyAtNoneWithoutTheModel() async {
        let output = await finish(
            "is it ready question mark new line email sam at example dot com",
            configuration(.none, multiline: true),
            cleaner: nil
        )
        #expect(output.text == "is it ready?\nEmail sam@example.com")
    }

    @Test func aSpokenLineBreakIsANewlineOnlyWhereTheFieldTakesLines() async {
        let cleaner = ScriptedCleaner(reply: Self.tidy)
        let multiline = await finish("thanks new paragraph see you soon", configuration(.light, multiline: true), cleaner: cleaner)
        #expect(multiline.text == "Thanks\n\nSee you soon.")
        let singleLine = await finish("thanks new paragraph see you soon", configuration(.light), cleaner: cleaner)
        #expect(singleLine.text == "Thanks see you soon.")
    }

    @Test func aSnippetWinsOverACommandWithTheSameWords() async {
        let heart = Snippet(trigger: "heart emoji", expansion: "<3")
        let output = await finish("thanks heart emoji", configuration(.none, snippets: [heart]), cleaner: nil)
        #expect(output.text == "thanks <3")
    }

    /// "Number 1, … Number two, …" becomes a numbered list; Undo puts back what was said.
    @Test func spokenListMarkersBecomeAList() async {
        let transcript = "List of to-do tasks for Acme. Number 1, we have to work on the launch. "
            + "Number two, need to fix the Android build."
        let cleaner = ScriptedCleaner { $0 }
        let output = await finish(transcript, configuration(.medium, multiline: true), cleaner: cleaner)
        #expect(await cleaner.requests.first?.text
            == "List of to-do tasks for Acme. S1 we have to work on the launch. S2 need to fix the Android build.")
        #expect(output.text
            == "List of to-do tasks for Acme:\n1. We have to work on the launch.\n2. Need to fix the Android build.")
        #expect(output.uncleanedText == transcript)
    }

    /// "First is …" and "Number one is …": the "is" introduces the item, so the line doesn't
    /// start with it. Undo still puts back what was said.
    @Test func anIsThatIntroducesAnItemIsNotPartOfIt() async {
        let cleaner = ScriptedCleaner { $0 }
        let ordinals = await finish(
            "I have a few to-do items. First is work on getting the weed killer. Second is go to the hardware store and buy the weed killer.",
            configuration(.medium, multiline: true),
            cleaner: cleaner
        )
        #expect(ordinals.text
            == "I have a few to-do items:\n1. Work on getting the weed killer.\n2. Go to the hardware store and buy the weed killer.")
        let transcript = "Number one is ship the release. Number two is fix the build."
        let numbered = await finish(transcript, configuration(.medium, multiline: true), cleaner: cleaner)
        #expect(numbered.text == "1. Ship the release\n2. Fix the build")
        #expect(numbered.uncleanedText == transcript)
    }

    @Test func listMarkersStayWordsWhereNothingIsLaidOut() async {
        let transcript = "Number 1, milk. Number two, eggs."
        let cleaner = ScriptedCleaner { $0 }
        let singleLine = await finish(transcript, configuration(.medium), cleaner: cleaner)
        #expect(singleLine.text == transcript)
        let light = await finish(transcript, configuration(.light, multiline: true), cleaner: cleaner)
        #expect(light.text == transcript)
    }

    /// The model sees only the body, so it cannot move names between the greeting and the
    /// sign-off.
    @Test func aLetterIsFramedAndOnlyItsBodyIsCleaned() async {
        let transcript = "Dear sir oh madam, I'm writing about my passport renewal. Kind regards Jordan Lee."
        let cleaner = ScriptedCleaner { $0.replacingOccurrences(of: "I'm", with: "I am") }
        let output = await finish(transcript, configuration(.medium, multiline: true), cleaner: cleaner)
        #expect(await cleaner.requests.first?.text == "I'm writing about my passport renewal.")
        #expect(output.text == "Dear Sir or Madam,\n\nI am writing about my passport renewal.\n\nKind regards,\nJordan Lee")
        #expect(output.uncleanedText == transcript)
        #expect(!output.fellBack)
    }

    @Test func anUnpunctuatedNoteIsFramed() async {
        let output = await finish(
            "Hi John thanks for the update I will review it tomorrow cheers Sam.",
            configuration(.medium, multiline: true),
            cleaner: ScriptedCleaner(reply: Self.tidy)
        )
        #expect(output.text == "Hi John,\n\nThanks for the update I will review it tomorrow.\n\nCheers,\nSam")
    }

    @Test func aLetterIsStillFramedWhenCleanupFallsBack() async {
        let output = await finish(
            "Hi John thanks for the update cheers Sam.",
            configuration(.medium, multiline: true),
            cleaner: ScriptedCleaner { _ in "" }
        )
        #expect(output.fellBack)
        #expect(output.text == "Hi John,\n\nThanks for the update\n\nCheers,\nSam")
    }

    @Test func aLetterIsNotFramedInASingleLineField() async {
        let transcript = "Hi John thanks for the update cheers Sam."
        let output = await finish(transcript, configuration(.medium), cleaner: ScriptedCleaner { $0 })
        #expect(output.text == transcript)
    }

    @Test func placeholdersInTheSignatureStayOutOfTheModelsText() async {
        let name = Snippet(trigger: "my name", expansion: "Jordan Lee")
        let cleaner = ScriptedCleaner(reply: Self.tidy)
        let output = await finish(
            "Hi John, send my calendar link please. Cheers my name",
            configuration(.medium, multiline: true, snippets: [calendar, name]),
            cleaner: cleaner
        )
        let request = await cleaner.requests.first
        #expect(request?.text == "send S1 please.")
        #expect(request?.options.placeholders == ["⟦S1⟧"])
        #expect(output.text == "Hi John,\n\nSend https://cal.example.com/me please..\n\nCheers,\nJordan Lee")
    }

    @Test func aParagraphBreakAfterTheGreetingAddsNoBlankLines() async {
        let output = await finish(
            "Hi John new paragraph thanks for the update cheers Sam",
            configuration(.medium, multiline: true),
            cleaner: ScriptedCleaner { $0 }
        )
        #expect(output.text == "Hi John,\n\nThanks for the update\n\nCheers,\nSam")
    }

    // MARK: - Cleanup model turned off

    /// Turning the model off in Advanced is a choice, not a failure: Medium still removes
    /// fillers and applies snippets and vocabulary, nothing is reworded, and nothing is flagged.
    @Test func withTheCleanupModelOffMediumRemovesFillersWithoutFallingBack() async {
        let output = await finish("um send my calendar link to nerd storm", configuration(.medium), cleaner: nil)
        #expect(output.text == "send https://cal.example.com/me to Nerdstorm")
        #expect(output.uncleanedText == "um send https://cal.example.com/me to Nerdstorm")
        #expect(!output.fellBack)
        #expect(output.fallbackReason == nil)
        #expect(output.cleanupMs == 0)
    }

    @Test func withTheCleanupModelOffListsAreStillFormattedAndLightKeepsEveryWord() async {
        let transcript = "um we need three things: first, milk; second, eggs; and third, bread."
        let medium = await finish(transcript, configuration(.medium, multiline: true), cleaner: nil)
        #expect(medium.text == "we need three things:\n1. Milk\n2. Eggs\n3. Bread")
        #expect(!medium.fellBack)

        let light = await finish(transcript, configuration(.light, multiline: true), cleaner: nil)
        #expect(light.text == transcript, "Light removes nothing and formats nothing without the model")
        #expect(!light.fellBack)
    }

    @Test func withTheCleanupModelOffALetterIsStillFramed() async {
        let output = await finish(
            "um dear team the build is green. Regards Sam",
            configuration(.medium, multiline: true),
            cleaner: nil
        )
        #expect(output.text == "Dear team,\n\nThe build is green.\n\nRegards,\nSam")
        #expect(!output.fellBack)
    }

    @Test func processWithoutACleanerStillTranscribes() async throws {
        let processor = DictationProcessor(transcriber: FakeTranscriber(transcript: " um ship it on friday "), cleaner: nil)
        let output = try await processor.process([0.1, 0.2], configuration: configuration(.high))
        #expect(output.text == "ship it on friday")
        #expect(output.rawTranscript == "um ship it on friday")
        #expect(!output.fellBack)
    }

    @Test func anEmptyTranscriptIsNothingToInsert() async {
        let cleaner = ScriptedCleaner { _ in
            Issue.record("the model should not run")
            return ""
        }
        let output = await finish("   ", configuration(.medium), cleaner: cleaner)
        #expect(output.isEmpty)
        #expect(output.rawTranscript.isEmpty)
    }

    @Test func aTranscriptionFailureIsReported() async {
        let processor = DictationProcessor(
            transcriber: FakeTranscriber(error: FakeFailure(message: "model not loaded")),
            cleaner: ScriptedCleaner { $0 }
        )
        await #expect(throws: DictationError.transcriptionFailed("model not loaded")) {
            try await processor.process([0.1], configuration: configuration(.medium))
        }
    }

    @Test func processRunsSpeechToTextThenCleanup() async throws {
        let processor = DictationProcessor(
            transcriber: FakeTranscriber(transcript: " ship it on friday "),
            cleaner: ScriptedCleaner(reply: Self.tidy)
        )
        let output = try await processor.process([0.1, 0.2], configuration: configuration(.high))
        #expect(output.text == "Ship it on friday.")
        #expect(output.transcriptionMs >= 0)
    }
}
