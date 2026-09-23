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

    private func configuration(_ level: CleanupLevel, multiline: Bool = false) -> DictationProcessor.Configuration {
        .init(
            level: level,
            snippets: [calendar],
            vocabulary: [nerdstorm],
            vocabularyPromptLimit: 50,
            vocabularySimilarityThreshold: 0.8,
            multiline: multiline
        )
    }

    private func finish(_ transcript: String, _ configuration: DictationProcessor.Configuration, cleaner: any Cleaner) async -> DictationProcessor.Output {
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
        #expect(request?.text == "send ⟦S1⟧ to Nerdstorm", "fillers, snippets and vocabulary are handled before the model")
        #expect(request?.options.placeholders == ["⟦S1⟧"])
        #expect(request?.options.vocabulary == ["Nerdstorm"])
        #expect(output.text == "Send https://cal.example.com/me to Nerdstorm.")
        #expect(output.uncleanedText == "um send https://cal.example.com/me to Nerdstorm")
        #expect(!output.fellBack)
    }

    @Test func aDamagedPlaceholderFallsBackWithSnippetsStillExpanded() async {
        let cleaner = ScriptedCleaner { text in Self.tidy(text.replacingOccurrences(of: "⟦S1⟧", with: "S1")) }
        let output = await finish("um send my calendar link to nerd storm", configuration(.medium), cleaner: cleaner)
        #expect(output.fellBack)
        #expect(output.fallbackReason == "changed a snippet placeholder")
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
