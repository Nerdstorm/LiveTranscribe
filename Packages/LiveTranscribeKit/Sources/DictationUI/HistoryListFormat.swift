import Foundation
import Persistence
import Shared

/// Words and numbers for the history window, from the plain values a ``DictationRecord`` keeps.
enum HistoryListFormat {
    /// "10:42" for a dictation made today, "12 Sep 2026 at 10:42" (in the user's locale) otherwise.
    static func time(_ date: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        var style = Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        if calendar.isDate(date, inSameDayAs: now) {
            style = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        }
        return date.formatted(style)
    }

    /// The app the text went to, or a stand-in when it wasn't known.
    static func appName(_ record: DictationRecord) -> String {
        guard let name = record.appName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return "Unknown app"
        }
        return name
    }

    /// The cleanup level's name for a stored raw value; the raw value itself if it is unknown.
    static func cleanupLevel(_ rawValue: String) -> String {
        CleanupLevel(rawValue: rawValue)?.displayName ?? rawValue
    }

    /// How the text reached the app, for a stored delivery value (see the dictation controller).
    static func delivery(_ rawValue: String) -> String {
        switch rawValue {
        case "accessibility": "Typed into the field"
        case "paste": "Pasted"
        case "clipboard": "Left on the clipboard"
        case "refused": "Not inserted: password field"
        case "nothing": "Nothing to insert"
        case "failed": "Not inserted"
        default: rawValue
        }
    }

    /// Seconds with one decimal: "4.2 s".
    static func seconds(fromMs ms: Int, locale: Locale = .current) -> String {
        let seconds = Double(ms) / 1_000
        return seconds.formatted(.number.precision(.fractionLength(1)).locale(locale)) + " s"
    }

    /// Whole milliseconds: "820 ms", "1,250 ms".
    static func milliseconds(_ ms: Int, locale: Locale = .current) -> String {
        ms.formatted(.number.locale(locale)) + " ms"
    }
}
