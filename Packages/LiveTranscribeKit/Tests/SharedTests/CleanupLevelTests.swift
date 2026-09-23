import Foundation
import Shared
import Testing

@Suite("CleanupLevel")
struct CleanupLevelTests {
    @Test func onlyNoneSkipsTheLanguageModel() {
        #expect(CleanupLevel.allCases.filter { !$0.usesLanguageModel } == [.none])
    }

    @Test func mediumAndHighRemoveFillersResolveCorrectionsAndFormatLists() {
        for level in CleanupLevel.allCases {
            let expected = level == .medium || level == .high
            #expect(level.removesFillers == expected)
            #expect(level.resolvesSelfCorrections == expected)
            #expect(level.formatsLists == expected)
        }
        #expect(CleanupLevel.allCases.filter(\.allowsRewording) == [.high])
    }

    /// Snippets and vocabulary run before the level is looked at, so None's line must not
    /// promise the text exactly as heard. The same line shows for the live transcript, which
    /// applies neither, so it says they are dictation's.
    @Test func noneSaysSnippetsAndVocabularyStillApplyToDictation() {
        let summary = CleanupLevel.none.summary
        #expect(summary.contains("snippets") && summary.contains("vocabulary"))
        #expect(summary.contains("dictation"))
        #expect(!summary.localizedCaseInsensitiveContains("exactly"))
        for level in CleanupLevel.allCases {
            #expect(!level.summary.isEmpty && !level.summary.hasSuffix("."), "one line, no full stop, like the others")
        }
    }

    @Test func wordRatioBoundsWidenWithTheLevel() {
        #expect(CleanupLevel.light.wordRatioBounds == 0.8...1.2)
        #expect(CleanupLevel.medium.wordRatioBounds == 0.5...1.2)
        #expect(CleanupLevel.high.wordRatioBounds == 0.4...1.3)
    }

    @Test func storesAsItsRawValue() throws {
        #expect(CleanupLevel(rawValue: "medium") == .medium)
        let data = try JSONEncoder().encode([CleanupLevel.high])
        #expect(String(decoding: data, as: UTF8.self) == #"["high"]"#)
    }
}
