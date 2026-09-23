@testable import DictationUI
import Foundation
import Persistence
import Shared
import Testing

@Suite("History settings")
@MainActor
struct HistorySettingsModelTests {
    // MARK: - Retention options

    @Test func theStandardChoicesAreOfferedForeverFirst() {
        let options = HistorySettingsRetentionOption.options(including: 0)
        #expect(options.map(\.days) == [0, 7, 30, 90, 365])
        #expect(options.map(\.title) == ["Forever", "7 days", "30 days", "90 days", "1 year"])
    }

    @Test func theDefaultKeepsEverything() {
        #expect(AppSettings.defaults.dictation.historyRetentionDays == 0)
        #expect(HistorySettingsRetentionOption(days: 0).title == "Forever")
    }

    @Test func anUnusualStoredValueIsShownInOrder() {
        let options = HistorySettingsRetentionOption.options(including: 14)
        #expect(options.map(\.days) == [0, 7, 14, 30, 90, 365])
        #expect(options.map(\.title).contains("14 days"))
    }

    @Test func aStoredValueTheControllerClampsShowsWhatIsInEffect() {
        let tooLong = HistorySettingsRetentionOption.options(including: 99_999)
        #expect(tooLong.last == HistorySettingsRetentionOption(days: 99_999))
        #expect(tooLong.last?.title == "3650 days")
        #expect(AppSettings.defaults.dictation.with(retention: 99_999).sanitized().historyRetentionDays == 3_650)

        // Negative means keep everything, and replaces Forever instead of listing it twice.
        let negative = HistorySettingsRetentionOption.options(including: -1)
        #expect(negative.map(\.days) == [-1, 7, 30, 90, 365])
        #expect(negative.first?.title == "Forever")
    }

    // MARK: - Clearing

    @Test func clearingDeletesEverything() async throws {
        let history = MemoryDictationHistory(records: [HistoryListFixtures.record(text: "hello")])
        let model = HistorySettingsModel(history: history)
        let cleared = await model.clear()
        #expect(cleared)
        #expect(model.didClear)
        #expect(model.errorMessage == nil)
        #expect(!model.isClearing)
        #expect(try await history.all().isEmpty)
    }

    @Test func aFailedClearIsReportedAndKeepsTheHistory() async throws {
        let history = MemoryDictationHistory(records: [HistoryListFixtures.record(text: "hello")])
        await history.setFailure(.rewriteFailed("disk full"))
        let model = HistorySettingsModel(history: history)
        let cleared = await model.clear()
        #expect(!cleared)
        #expect(!model.didClear)
        #expect(model.errorMessage?.contains("disk full") == true)
        await history.setFailure(nil)
        #expect(try await history.all().count == 1)
    }
}

private extension DictationSettings {
    func with(retention days: Int) -> DictationSettings {
        var copy = self
        copy.historyRetentionDays = days
        return copy
    }
}
