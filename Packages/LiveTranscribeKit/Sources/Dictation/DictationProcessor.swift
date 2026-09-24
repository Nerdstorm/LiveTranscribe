import Cleanup
import Foundation
import Shared
import Snippets
import Styles
import Transcription
import Vocabulary

/// Turns one recording into the text to insert: speech-to-text, snippets, spoken commands and
/// vocabulary, cleanup at the chosen level, then layout and the snippets' expansions.
///
/// Snippet triggers, emoji, addresses and spoken line breaks become opaque placeholders before
/// the language model runs, so the model can neither see nor change them (see
/// ``PreparedDictation``). At Medium and High, in fields that take several lines, spoken lists
/// and letters are laid out; a letter's greeting and sign-off are laid out before the model
/// runs, and only its body is cleaned. If cleanup is rejected or times out, the text before
/// cleanup is used, with snippets, commands, vocabulary and layout still applied.
///
/// Without a cleaner (cleanup turned off in Settings › Advanced) each level still applies its
/// rules that need no model, filler removal and layout at Medium and High, and nothing is
/// reworded. That was chosen, so it is not reported as a fallback.
public struct DictationProcessor: Sendable {
    /// Everything that shapes one dictation's text, read fresh for each dictation.
    public struct Configuration: Sendable {
        public var level: CleanupLevel
        public var snippets: [Snippet]
        public var vocabulary: [VocabularyEntry]
        /// Most vocabulary terms listed in the cleanup prompt.
        public var vocabularyPromptLimit: Int
        /// How close a spoken word must be to a term for the term to be listed in the prompt.
        public var vocabularySimilarityThreshold: Double
        /// The target field takes several lines, so spoken line breaks are newlines and spoken
        /// lists and letters can be laid out on lines.
        public var multiline: Bool

        public init(
            level: CleanupLevel,
            snippets: [Snippet],
            vocabulary: [VocabularyEntry],
            vocabularyPromptLimit: Int,
            vocabularySimilarityThreshold: Double,
            multiline: Bool
        ) {
            self.level = level
            self.snippets = snippets
            self.vocabulary = vocabulary
            self.vocabularyPromptLimit = vocabularyPromptLimit
            self.vocabularySimilarityThreshold = vocabularySimilarityThreshold
            self.multiline = multiline
        }
    }

    public struct Output: Sendable, Equatable {
        /// Exactly what speech-to-text heard.
        public let rawTranscript: String
        /// The transcript with snippets, spoken commands and vocabulary applied but neither
        /// cleaned nor laid out: what Undo AI edit puts back.
        public let uncleanedText: String
        /// What to insert.
        public let text: String
        public let fellBack: Bool
        public let fallbackReason: String?
        public let transcriptionMs: Int
        public let cleanupMs: Int

        /// Nothing was heard.
        public var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private let transcriber: any Transcriber
    private let cleaner: (any Cleaner)?

    /// - Parameter cleaner: The cleanup model, or `nil` when cleanup is turned off. Like the
    ///   model, that setting is read once at launch.
    public init(transcriber: any Transcriber, cleaner: (any Cleaner)?) {
        self.transcriber = transcriber
        self.cleaner = cleaner
    }

    public func process(_ samples: [Float], configuration: Configuration) async throws -> Output {
        let started = ContinuousClock.now
        let signposter = Log.transcriptionSignposter
        let interval = signposter.beginInterval("Dictation STT", id: signposter.makeSignpostID())
        let transcript: String
        do {
            transcript = try await transcriber.transcribe(samples, sampleRate: AudioFormat.sampleRate)
            signposter.endInterval("Dictation STT", interval)
        } catch {
            signposter.endInterval("Dictation STT", interval)
            throw DictationError.transcriptionFailed(error.localizedDescription)
        }
        let transcriptionMs = started.duration(to: .now).wholeMilliseconds
        try Task.checkCancellation()
        return await Self.finish(
            transcript: transcript,
            transcriptionMs: transcriptionMs,
            configuration: configuration,
            cleaner: cleaner
        )
    }

    /// Everything after speech-to-text, separated so it can be tested without audio.
    static func finish(
        transcript: String,
        transcriptionMs: Int,
        configuration: Configuration,
        cleaner: (any Cleaner)?
    ) async -> Output {
        let raw = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            return Output(rawTranscript: "", uncleanedText: "", text: "", fellBack: false, fallbackReason: nil,
                          transcriptionMs: transcriptionMs, cleanupMs: 0)
        }

        let prepared = PreparedDictation(transcript: raw, configuration: configuration)
        let uncleaned = prepared.uncleaned
        guard configuration.level.usesLanguageModel else {
            return Output(rawTranscript: raw, uncleanedText: uncleaned, text: uncleaned, fellBack: false,
                          fallbackReason: nil, transcriptionMs: transcriptionMs, cleanupMs: 0)
        }

        // A letter's greeting and sign-off are laid out already; the model cleans the body.
        let frame = prepared.frame(level: configuration.level)
        let body = frame?.body ?? prepared.text
        let segment = Segment(id: UUID(), sessionID: UUID(), startMs: 0, endMs: 0, rawText: body)
        let cleaned: CleanedSegment
        if let cleaner {
            let options = CleanupOptions(
                level: configuration.level,
                vocabulary: VocabularySelector(
                    entries: configuration.vocabulary,
                    similarityThreshold: configuration.vocabularySimilarityThreshold
                ).relevantTerms(for: body, limit: configuration.vocabularyPromptLimit),
                placeholders: prepared.placeholders.filter { body.contains($0) }
            )
            cleaned = await cleaner.clean(segment, context: [], options: options)
        } else {
            // Placeholders are single words that are never fillers, so they come through intact.
            cleaned = CleanedSegment(
                segment: segment,
                cleanedText: CleanupExecutor.deterministicCleanup(of: body, level: configuration.level),
                fellBack: false,
                fallbackReason: nil,
                latencyMs: 0
            )
        }

        let assembled = frame?.assembled(body: cleaned.cleanedText) ?? cleaned.cleanedText
        guard let text = prepared.finished(assembled) else {
            // The guard checks placeholders, so this means a later step damaged one.
            Log.dictation.error("Placeholders could not be restored; inserting the uncleaned text")
            return Output(rawTranscript: raw, uncleanedText: uncleaned, text: uncleaned, fellBack: true,
                          fallbackReason: "placeholders could not be restored", transcriptionMs: transcriptionMs,
                          cleanupMs: cleaned.latencyMs)
        }
        return Output(rawTranscript: raw, uncleanedText: uncleaned, text: text, fellBack: cleaned.fellBack,
                      fallbackReason: cleaned.fallbackReason, transcriptionMs: transcriptionMs,
                      cleanupMs: cleaned.latencyMs)
    }
}

public enum DictationError: LocalizedError, Equatable {
    case transcriptionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .transcriptionFailed(let message): "Speech-to-text failed: \(message)"
        }
    }
}
