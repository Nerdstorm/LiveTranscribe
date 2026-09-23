@testable import DictationUI
import Foundation
import Testing

@Suite("HistoryListFormat")
struct HistoryListFormatTests {
    private let posix = Locale(identifier: "en_US_POSIX")

    @Test func showsOnlyTheTimeForToday() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let earlierToday = now.addingTimeInterval(-60)
        let lastWeek = now.addingTimeInterval(-7 * 86_400)
        let today = HistoryListFormat.time(earlierToday, now: now, calendar: calendar, locale: posix)
        let older = HistoryListFormat.time(lastWeek, now: now, calendar: calendar, locale: posix)
        #expect(!today.contains("2026") && !today.contains("2025"))
        #expect(older.count > today.count, "older dictations include the date")
    }

    @Test func namesDeliveriesLevelsAndMissingApps() {
        #expect(HistoryListFormat.delivery("accessibility") == "Typed into the field")
        #expect(HistoryListFormat.delivery("paste") == "Pasted")
        #expect(HistoryListFormat.delivery("clipboard") == "Left on the clipboard")
        #expect(HistoryListFormat.delivery("something-new") == "something-new")
        #expect(HistoryListFormat.cleanupLevel("medium") == "Medium")
        #expect(HistoryListFormat.cleanupLevel("custom") == "custom")
        #expect(HistoryListFormat.appName(HistoryListFixtures.record(text: "x", app: nil)) == "Unknown app")
        #expect(HistoryListFormat.appName(HistoryListFixtures.record(text: "x", app: "  ")) == "Unknown app")
    }

    @Test func formatsDurations() {
        #expect(HistoryListFormat.seconds(fromMs: 4_200, locale: posix) == "4.2 s")
        #expect(HistoryListFormat.seconds(fromMs: 60, locale: posix) == "0.1 s")
        #expect(HistoryListFormat.milliseconds(820, locale: posix) == "820 ms")
    }
}
