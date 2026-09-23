import Foundation
import Shared

/// How a ``DictationRecord`` is written to and read from one line of the history file.
///
/// Dates are ISO 8601 in UTC with milliseconds ("2026-09-24T10:15:30.125Z"). Foundation's
/// fractional-second formatter truncates the binary value, so 0.123 s can come out as ".122";
/// this type formats the whole seconds with Foundation and adds the milliseconds itself, and
/// rounds what it parses back to the millisecond (see ``DictationRecord/createdAt``).
enum DictationRecordCoding {
    private static let wholeSeconds = Date.ISO8601FormatStyle(timeZone: .gmt)
    private static let fractionalSeconds = Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .gmt)

    /// The dates a timestamp can hold: ISO 8601's four-digit years, 0001-01-01T00:00:00Z up to
    /// the end of 9999 (`Date.distantPast` and `Date.distantFuture` are inside). Later years do
    /// not read back, and a date that is not finite cannot be formatted at all, so such a record
    /// is refused rather than written as a line that could never be read.
    static let writableDates = Date(timeIntervalSinceReferenceDate: -63_114_076_800)
        ..< Date(timeIntervalSinceReferenceDate: 252_423_993_600)

    /// JSON with sorted keys, so lines are stable and easy to diff.
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            guard let text = timestamp(from: date) else {
                throw EncodingError.invalidValue(date, EncodingError.Context(
                    codingPath: encoder.codingPath,
                    debugDescription: "The date is outside the years 1 to 9999 that the history file can hold"
                ))
            }
            var container = encoder.singleValueContainer()
            try container.encode(text)
        }
        return encoder
    }

    /// Accepts timestamps with or without fractional seconds, so a hand-edited or older line
    /// still reads.
    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            // The debug description stays generic: a corrupt line can hold user text.
            guard let date = date(fromTimestamp: try container.decode(String.self)) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not an ISO 8601 timestamp")
            }
            return date
        }
        return decoder
    }

    /// The timestamp for `date` to the nearest millisecond, or `nil` when it is outside
    /// ``writableDates``.
    static func timestamp(from date: Date) -> String? {
        let rounded = DictationRecord.millisecondPrecision(date)
        // `contains` is false for NaN, so the arithmetic below only ever sees finite values of
        // at most 13 digits, which a Double holds exactly.
        guard writableDates.contains(rounded) else { return nil }
        let milliseconds = (rounded.timeIntervalSinceReferenceDate * 1000).rounded()
        let seconds = (milliseconds / 1000).rounded(.down)
        // The reference date is a whole second, so this is also the fraction in UTC.
        let fraction = Int(milliseconds - seconds * 1000)
        var text = Date(timeIntervalSinceReferenceDate: seconds).formatted(wholeSeconds)
        if text.hasSuffix("Z") { text.removeLast() }
        return text + String(format: ".%03ldZ", fraction)
    }

    /// The date a timestamp names, to the nearest millisecond, or `nil` when it is not ISO 8601.
    static func date(fromTimestamp text: String) -> Date? {
        let parsed = (try? Date(text, strategy: fractionalSeconds)) ?? (try? Date(text, strategy: wholeSeconds))
        return parsed.map(DictationRecord.millisecondPrecision)
    }
}

/// Counts the lines a read skipped, so one log entry per operation says how many and why,
/// without quoting any of their content.
struct UnreadableLines {
    private(set) var count = 0
    private var firstReason: String?

    mutating func record(_ error: any Error) {
        count += 1
        if firstReason == nil { firstReason = Self.reason(for: error) }
    }

    /// Logs a summary when anything was skipped. `operation` names what was being done.
    func log(during operation: String) {
        guard count > 0 else { return }
        Log.persistence.error(
            "Dictation history: found \(count, privacy: .public) unreadable line(s) during \(operation, privacy: .public); first: \(firstReason ?? "unknown", privacy: .public)"
        )
    }

    /// Names only the kind of failure and the record's own field names, never line content.
    private static func reason(for error: any Error) -> String {
        guard let error = error as? DecodingError else { return "not a record" }
        switch error {
        case .keyNotFound(let key, _):
            return "missing field \(key.stringValue)"
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            return "invalid field \(fieldPath(context))"
        case .dataCorrupted(let context):
            return context.codingPath.isEmpty ? "not valid JSON" : "invalid field \(fieldPath(context))"
        @unknown default:
            return "not a record"
        }
    }

    private static func fieldPath(_ context: DecodingError.Context) -> String {
        context.codingPath.map(\.stringValue).joined(separator: ".")
    }
}
