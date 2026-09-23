import Foundation
@testable import Persistence
import Testing

/// The record's own rules: millisecond `createdAt` whichever way it is made, and the one prune
/// comparison every history shares.
@Suite("DictationRecord")
struct DictationRecordTests {
    private typealias Fixtures = DictationHistoryFixtures

    @Test("createdAt is kept to the nearest millisecond", arguments: [
        (0.1234, 0.123),
        (0.1235, 0.124),
        (0.9996, 1.0),
        (-0.0004, 0.0),
        (-1.2346, -1.235),
    ])
    func createdAtIsKeptToTheNearestMillisecond(offset: Double, expectedOffset: Double) {
        let record = Fixtures.record("x", createdAt: Fixtures.baseDate.addingTimeInterval(offset))
        let expected = Date(timeIntervalSinceReferenceDate: Fixtures.baseDate.timeIntervalSinceReferenceDate + expectedOffset)

        #expect(abs(record.createdAt.timeIntervalSince(expected)) < 1e-6)
        #expect(record.createdAt == DictationRecord.millisecondPrecision(record.createdAt))
    }

    /// Decoding goes through the same initialiser, so a record decoded by any decoder (here one
    /// with Foundation's default date strategy) keeps the millisecond rule too.
    @Test func decodingWithAnyDecoderKeepsTheMillisecondRule() throws {
        let record = Fixtures.record("x", offsetMs: 42)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        object["createdAt"] = record.createdAt.timeIntervalSinceReferenceDate + 0.000_4

        let decoded = try JSONDecoder().decode(DictationRecord.self, from: JSONSerialization.data(withJSONObject: object))

        #expect(decoded == record)
    }

    @Test func aPlainJSONRoundTripKeepsEveryField() throws {
        let record = DictationRecord(
            id: UUID(),
            createdAt: Date(timeIntervalSinceReferenceDate: 800_000_000.123_456),
            appName: "Mail",
            bundleIdentifier: "com.apple.mail",
            rawText: "raw",
            cleanedText: "Cleaned.",
            cleanupLevel: "light",
            fellBack: true,
            fallbackReason: "guard rejected the output",
            delivery: "paste",
            audioDurationMs: 1_500,
            latencyMs: 250
        )

        #expect(try JSONDecoder().decode(DictationRecord.self, from: JSONEncoder().encode(record)) == record)
    }

    @Test func aMissingRequiredFieldIsADecodingError() throws {
        let record = Fixtures.record("x", offsetMs: 0)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        object["rawText"] = nil
        let data = try JSONSerialization.data(withJSONObject: object)

        #expect(throws: DecodingError.self) { try JSONDecoder().decode(DictationRecord.self, from: data) }
    }

    /// Strictly before the cutoff is pruned; at or after it is kept.
    @Test(arguments: [(-1, true), (0, false), (1, false)])
    func pruningIsStrictlyBeforeTheCutoff(offsetMs: Int, pruned: Bool) {
        let cutoff = Fixtures.baseDate.addingTimeInterval(5)
        let record = Fixtures.record("x", offsetMs: 5_000 + offsetMs)

        #expect(record.isPruned(olderThan: cutoff) == pruned)
    }
}
