import Foundation
import Shared
import Testing

@Suite("CleanupLevel")
struct CleanupLevelTests {
    @Test func onlyNoneSkipsTheLanguageModel() {
        #expect(CleanupLevel.allCases.filter { !$0.usesLanguageModel } == [.none])
    }

    @Test func standardAndDeepRemoveFillersResolveCorrectionsLayOutTextAndWriteNumbers() {
        for level in CleanupLevel.allCases {
            let expected = level != .none
            #expect(level.removesFillers == expected)
            #expect(level.resolvesSelfCorrections == expected)
            #expect(level.formatsLayout == expected)
            #expect(level.writesNumbers == expected)
        }
        #expect(CleanupLevel.allCases.filter(\.allowsRewording) == [.standard])
        #expect(CleanupLevel.allCases.filter(\.repairsAcrossSentences) == [.deep])
    }

    @Test func levelsAreOrderedFromLeastToMostChange() {
        #expect(CleanupLevel.allCases == [.none, .standard, .deep])
        #expect(CleanupLevel.allCases.sorted() == CleanupLevel.allCases)
        #expect(CleanupLevel.deep > .standard && CleanupLevel.none < .standard)
    }

    /// Snippets, vocabulary and spoken commands run before the level is looked at, so None's line
    /// must not promise the text exactly as heard. The same line shows for the live transcript,
    /// which applies none of them, so it says they are dictation's.
    @Test func noneSaysSnippetsVocabularyAndCommandsStillApplyToDictation() {
        let summary = CleanupLevel.none.summary
        #expect(summary.contains("snippets") && summary.contains("vocabulary") && summary.contains("spoken commands"))
        #expect(summary.contains("dictation"))
        #expect(!summary.localizedCaseInsensitiveContains("exactly"))
        for level in CleanupLevel.allCases {
            #expect(!level.summary.isEmpty && !level.summary.hasSuffix("."), "one line, no full stop, like the others")
        }
    }

    @Test func storesAsItsRawValue() throws {
        #expect(CleanupLevel(rawValue: "standard") == .standard)
        #expect(CleanupLevel(rawValue: "deep") == .deep)
        let data = try JSONEncoder().encode([CleanupLevel.standard])
        #expect(String(decoding: data, as: UTF8.self) == #"["standard"]"#)
    }

    /// Light, Medium and High became Standard; a stored name of them reads as Standard, and an
    /// unknown one as nothing.
    @Test func theEarlierLevelsReadAsStandard() {
        for name in ["light", "medium", "high"] {
            #expect(CleanupLevel(storedValue: name) == .standard)
            #expect(CleanupLevel(rawValue: name) == nil)
        }
        for level in CleanupLevel.allCases {
            #expect(CleanupLevel(storedValue: level.rawValue) == level)
        }
        #expect(CleanupLevel(storedValue: "extreme") == nil)
        #expect(CleanupLevel(storedValue: "Medium") == nil)
    }
}
