import Foundation

/// Turns the user's retention setting into the date passed to ``DictationHistory/prune(olderThan:)``.
///
/// History keeps everything by default (decision H2), so a retention of 0 days means "no limit"
/// rather than "keep nothing"; turning history off is a separate setting.
public enum HistoryRetention {
    /// The oldest creation date to keep, or `nil` when nothing should be pruned.
    ///
    /// - Parameters:
    ///   - now: The current time; passed in so callers and tests control the clock.
    ///   - retentionDays: Days of history to keep. Zero or less keeps everything.
    ///   - calendar: Days are calendar days, so across a daylight-saving change "7 days ago" is
    ///     the same wall-clock time a week earlier rather than exactly 168 hours.
    /// - Returns: `now` minus `retentionDays` calendar days, or `nil` to keep everything. A
    ///   retention too large for the calendar to represent also keeps everything.
    public static func cutoff(now: Date, retentionDays: Int, calendar: Calendar = .current) -> Date? {
        guard retentionDays > 0 else { return nil }
        return calendar.date(byAdding: .day, value: -retentionDays, to: now)
    }
}
