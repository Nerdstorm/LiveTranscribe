import Foundation

/// One finished dictation as kept in history: what was heard, what was delivered, where and how.
///
/// Both texts are kept so the history window can show what cleanup changed and so the user can
/// recover the raw transcript later. Plain strings stand in for the cleanup level and the delivery
/// route, so Persistence stays independent of the Styles and Insertion slices; the integrator
/// stores their raw values (for example `CleanupLevel.medium.rawValue`).
public struct DictationRecord: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    /// When the dictation was delivered, to the nearest millisecond.
    ///
    /// The history file stores milliseconds, so the record keeps the same precision from the
    /// start: a record reads back equal to the one appended, and every ``DictationHistory``
    /// prunes on the same boundary.
    public let createdAt: Date
    /// Name of the app the text went to, when it was known.
    public let appName: String?
    /// Bundle identifier of the app the text went to, when it was known.
    public let bundleIdentifier: String?
    /// The speech-to-text output before any cleanup.
    public let rawText: String
    /// The text that was delivered: cleaned, or the raw text when cleanup was off or fell back.
    public let cleanedText: String
    /// Raw value of the cleanup level in effect, such as "medium".
    public let cleanupLevel: String
    /// Whether cleanup was rejected or failed and the pre-cleanup text was delivered instead.
    public let fellBack: Bool
    /// Why cleanup fell back, for the history window and diagnostics. `nil` when it did not.
    public let fallbackReason: String?
    /// How the text reached the app, such as "accessibility", "paste" or "clipboard".
    public let delivery: String
    /// Length of the recorded audio.
    public let audioDurationMs: Int
    /// Time from hotkey release to delivery.
    public let latencyMs: Int

    /// `createdAt` is rounded to the nearest millisecond; every other value is kept as given.
    public init(
        id: UUID,
        createdAt: Date,
        appName: String?,
        bundleIdentifier: String?,
        rawText: String,
        cleanedText: String,
        cleanupLevel: String,
        fellBack: Bool,
        fallbackReason: String?,
        delivery: String,
        audioDurationMs: Int,
        latencyMs: Int
    ) {
        self.id = id
        self.createdAt = Self.millisecondPrecision(createdAt)
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.rawText = rawText
        self.cleanedText = cleanedText
        self.cleanupLevel = cleanupLevel
        self.fellBack = fellBack
        self.fallbackReason = fallbackReason
        self.delivery = delivery
        self.audioDurationMs = audioDurationMs
        self.latencyMs = latencyMs
    }

    /// Decodes through ``init(id:createdAt:appName:bundleIdentifier:rawText:cleanedText:cleanupLevel:fellBack:fallbackReason:delivery:audioDurationMs:latencyMs:)``
    /// so a record decoded by any decoder keeps `createdAt` to the millisecond too.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            createdAt: try container.decode(Date.self, forKey: .createdAt),
            appName: try container.decodeIfPresent(String.self, forKey: .appName),
            bundleIdentifier: try container.decodeIfPresent(String.self, forKey: .bundleIdentifier),
            rawText: try container.decode(String.self, forKey: .rawText),
            cleanedText: try container.decode(String.self, forKey: .cleanedText),
            cleanupLevel: try container.decode(String.self, forKey: .cleanupLevel),
            fellBack: try container.decode(Bool.self, forKey: .fellBack),
            fallbackReason: try container.decodeIfPresent(String.self, forKey: .fallbackReason),
            delivery: try container.decode(String.self, forKey: .delivery),
            audioDurationMs: try container.decode(Int.self, forKey: .audioDurationMs),
            latencyMs: try container.decode(Int.self, forKey: .latencyMs)
        )
    }
}

extension DictationRecord {
    /// `date` to the nearest millisecond, the precision a record keeps.
    ///
    /// Rounding works on the value `Date` stores (seconds since its 2001 reference date), so a
    /// rounded date survives a round trip through the history file bit for bit.
    static func millisecondPrecision(_ date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate * 1000).rounded() / 1000)
    }

    /// Whether ``DictationHistory/prune(olderThan:)`` removes this record: created strictly
    /// before `cutoff`, compared at the millisecond precision records keep. A record created
    /// exactly at the cutoff is kept. Every history uses this one rule so they cannot drift.
    func isPruned(olderThan cutoff: Date) -> Bool {
        // Written as "less than" so an invalid (NaN) cutoff removes nothing rather than everything.
        createdAt < Self.millisecondPrecision(cutoff)
    }
}
