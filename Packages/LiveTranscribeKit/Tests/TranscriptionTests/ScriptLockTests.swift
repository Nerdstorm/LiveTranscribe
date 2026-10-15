import Foundation
import Testing
@testable import Transcription

/// What a language told to Qwen3-ASR lets it write, read as the UTF-8 bytes its tokens write.
@Suite("Script lock")
struct ScriptLockTests {
    private let english = ScriptLock(script: .latin)
    private let sinhala = ScriptLock(script: .sinhala)

    /// Reads `text`'s bytes from a whole character: what's left unfinished, or `nil` if refused.
    private func read(_ text: String, _ lock: ScriptLock) -> PartialCharacter? {
        lock.partial(after: .nothing, reading: Array(text.utf8))
    }

    private func read(_ bytes: [UInt8], _ lock: ScriptLock, after partial: PartialCharacter = .nothing) -> PartialCharacter? {
        lock.partial(after: partial, reading: bytes)
    }

    @Test func englishWritesLatinLettersDigitsAndPunctuation() {
        #expect(read("Send the café’s report — 10% off, “naïve” résumé.\n- Item 2", english) == .nothing)
        #expect(read("Việt Nam, Łódź, ʻŌlelo", english) == .nothing, "Latin letters of every language")
        #expect(read("ක", english) == nil)
        #expect(read("我们", english) == nil)
        #expect(read("。", english) == nil, "CJK punctuation is Chinese, Japanese and Korean's")
        #expect(read("Привет", english) == nil)
    }

    /// The Sinhala fine-tune writes English words in English letters, and every lock but Latin's
    /// allows them.
    @Test func sinhalaWritesSinhalaAndEnglishWords() {
        #expect(read("මම Zoom meeting එකට යනවා.", sinhala) == .nothing)
        #expect(read("ප්‍රශ්නය", sinhala) == .nothing, "with the zero-width joiner of its conjuncts")
        #expect(read("我们", sinhala) == nil)
        #expect(read("我们开会。", ScriptLock(script: .han)) == .nothing)
        #expect(read("Hello", ScriptLock(script: .han)) == .nothing)
        #expect(read("ひらがなとカタカナと漢字", ScriptLock(script: .japanese)) == .nothing)
        #expect(read("한국어", ScriptLock(script: .korean)) == .nothing)
        #expect(read("한국어", ScriptLock(script: .japanese)) == nil)
    }

    /// "ක" is E0 B6 9A, and a token can end after its first bytes.
    @Test func aCharacterSplitAcrossTokensIsReadAcrossThem() throws {
        let started = try #require(read([0xE0, 0xB6], sinhala))
        #expect(!started.isWhole)
        #expect(read([0x9A], sinhala, after: started) == .nothing)
        #expect(read([0x9A, 0x61], sinhala, after: started) == .nothing, "then a whole character")
        #expect(read([0x61], sinhala, after: started) == nil, "it must be finished first")
        // Told English, the first byte already can't begin anything it allows.
        #expect(read([0xE0], english) == nil)
        // "—" (U+2014, E2 80 94) is allowed, so its first byte is.
        #expect(read([0xE2], english) != nil)
    }

    @Test func bytesThatArentUTF8AreRefused() {
        #expect(read([0x80], english) == nil, "a continuation byte with nothing to continue")
        #expect(read([0xC0, 0x80], english) == nil, "an overlong lead byte")
        #expect(read([0xFF], english) == nil)
    }

    // MARK: The vocabulary

    /// Qwen's vocabulary spells bytes in GPT-2's byte-level alphabet.
    @Test func tokensAreReadAsTheBytesTheirSpellingStandsFor() {
        #expect(LockedVocabulary.bytes(spelt: "Hello") == Array("Hello".utf8))
        #expect(LockedVocabulary.bytes(spelt: "Ġworld") == Array(" world".utf8))
        #expect(LockedVocabulary.bytes(spelt: "Ċ") == [0x0A])
        #expect(LockedVocabulary.bytes(spelt: "à¶") == [0xE0, 0xB6])
        #expect(LockedVocabulary.bytes(spelt: "ļ") == [0x9A])
        #expect(LockedVocabulary.bytes(spelt: "ක") == nil, "not in the alphabet")
    }

    private func vocabulary() throws -> LockedVocabulary {
        // "Hello", " world", "à¶" (E0 B6), "ļ" (9A), "æĪĳ" (我: E6 88 91) and "Ā" (00).
        let json = #"{"Hello": 0, "Ġworld": 1, "à¶": 2, "ļ": 3, "æĪĳ": 4, "Ā": 5}"#
        return try LockedVocabulary(vocabularyJSON: Data(json.utf8), endOfReply: [7])
    }

    @Test func theLockAllowsTheTokensThatWriteWhatItAllowsAndEndsAfterAWholeCharacter() throws {
        let vocabulary = try vocabulary()
        #expect(vocabulary.count == 6)
        // Tokens 6 and 8 are past the vocabulary, as Qwen's added tokens are; 7 ends the reply.
        #expect(vocabulary.allowed(by: english, after: .nothing, logitCount: 9) == [true, true, false, false, false, true, false, true, false])
        #expect(vocabulary.allowed(by: ScriptLock(script: .han), after: .nothing, logitCount: 9)[4])
        let started = try #require(sinhala.partial(after: .nothing, reading: vocabulary.bytes(of: 2)))
        #expect(
            vocabulary.allowed(by: sinhala, after: started, logitCount: 9) == [false, false, false, true, false, false, false, false, false],
            "only the end of the character, and no end of the reply"
        )
    }

    @Test func aVocabularyWithAGapInItsIdsIsRefused() {
        #expect(throws: LockedVocabulary.LoadError.missingToken(1)) {
            try LockedVocabulary(vocabularyJSON: Data(#"{"a": 0, "b": 2}"#.utf8), endOfReply: [])
        }
    }
}
