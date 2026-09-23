import Foundation
import Persistence
import Testing

@Suite("HistoryRetention")
struct HistoryRetentionTests {
    private static let now = Date(timeIntervalSince1970: 1_790_000_000)

    private static func calendar(_ timeZone: String) throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: timeZone))
        return calendar
    }

    /// History is on by default and keeps everything until the user sets a limit (decision H2).
    @Test("Zero or fewer days keeps everything", arguments: [0, -1, -30, Int.min])
    func zeroOrFewerDaysKeepsEverything(days: Int) {
        #expect(HistoryRetention.cutoff(now: Self.now, retentionDays: days) == nil)
    }

    @Test("A limit counts back that many days", arguments: [1, 7, 30, 365])
    func aLimitCountsBackThatManyDays(days: Int) throws {
        let cutoff = HistoryRetention.cutoff(now: Self.now, retentionDays: days, calendar: try Self.calendar("UTC"))
        #expect(cutoff == Self.now.addingTimeInterval(-Double(days) * 86_400))
    }

    /// Calendar days, not 24-hour blocks: across the start of daylight saving time, one day back
    /// from noon is noon the day before, 23 hours earlier.
    @Test func daysAreCalendarDaysAcrossADaylightSavingChange() throws {
        let calendar = try Self.calendar("America/New_York")
        let noonAfterTheChange = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 12)))
        let noonBefore = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 12)))

        let cutoff = HistoryRetention.cutoff(now: noonAfterTheChange, retentionDays: 1, calendar: calendar)

        #expect(cutoff == noonBefore)
        #expect(noonAfterTheChange.timeIntervalSince(noonBefore) == 23 * 3_600)
    }

    @Test func anAbsurdLimitStillKeepsEverything() {
        let cutoff = HistoryRetention.cutoff(now: Self.now, retentionDays: Int.max)
        #expect(cutoff.map { $0 < Date.distantPast } ?? true)
    }
}
