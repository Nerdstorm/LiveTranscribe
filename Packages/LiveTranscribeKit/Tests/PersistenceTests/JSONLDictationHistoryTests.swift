import Foundation
@testable import Persistence
import Testing

/// What the file-backed history adds to the shared behaviour: the file itself, how it is
/// written, and how file errors reach the caller. Damaged files and rewrites are covered in
/// ``JSONLDictationHistoryRewriteTests``.
@Suite("JSONLDictationHistory")
struct JSONLDictationHistoryTests {
    private typealias Fixtures = DictationHistoryFixtures
    private let file = HistoryFileFixture()

    @Test func defaultLocationIsTheHistoryFolderInApplicationSupport() {
        let url = JSONLDictationHistory.defaultURL(
            applicationSupport: URL(fileURLWithPath: "/Users/someone/Library/Application Support"),
            bundleIdentifier: "org.nerdstorm.LiveTranscribe"
        )
        #expect(url.path == "/Users/someone/Library/Application Support/org.nerdstorm.LiveTranscribe/History/dictations.jsonl")
    }

    @Test func everyFieldRoundTripsThroughTheFile() async throws {
        defer { file.cleanUp() }
        let full = DictationRecord(
            id: UUID(),
            // Sub-millisecond, as `Date()` is: the record keeps the millisecond it rounds to.
            createdAt: Fixtures.baseDate.addingTimeInterval(0.1234567),
            appName: "Notes \"work\"",
            bundleIdentifier: "com.apple.Notes",
            rawText: "um so the café in Zürich\nsecond line with a \\ backslash and / slash",
            cleanedText: "So the café in Zürich.\nSecond line with a \\ backslash and / slash.",
            cleanupLevel: "high",
            fellBack: true,
            fallbackReason: "timed out after 3.0s",
            delivery: "paste",
            audioDurationMs: 12_345,
            latencyMs: 678
        )
        let sparse = DictationRecord(
            id: UUID(),
            createdAt: Fixtures.baseDate.addingTimeInterval(60),
            appName: nil,
            bundleIdentifier: nil,
            rawText: "",
            cleanedText: "",
            cleanupLevel: "none",
            fellBack: false,
            fallbackReason: nil,
            delivery: "clipboard",
            audioDurationMs: 0,
            latencyMs: 0
        )
        try await JSONLDictationHistory(fileURL: file.fileURL).append(full)
        try await JSONLDictationHistory(fileURL: file.fileURL).append(sparse)

        // A new instance reads what another wrote, as the app does after a relaunch.
        #expect(try await JSONLDictationHistory(fileURL: file.fileURL).all() == [sparse, full])
        #expect(try file.lines().count == 2)
    }

    @Test func eachLineIsOneJSONObjectWithMillisecondISO8601Dates() async throws {
        defer { file.cleanUp() }
        let history = JSONLDictationHistory(fileURL: file.fileURL)
        try await history.append(Fixtures.record("hello", offsetMs: 125))

        let line = try #require(try file.lines().first)
        let object = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(Set(object.keys) == [
            "id", "createdAt", "appName", "bundleIdentifier", "rawText", "cleanedText", "cleanupLevel",
            "fellBack", "delivery", "audioDurationMs", "latencyMs",
        ])
        #expect(object["createdAt"] as? String == "2026-09-21T14:13:20.125Z")
    }

    /// Foundation's formatter truncates the binary value (0.123 s would be written as ".122"),
    /// so the file rounds to the nearest millisecond instead.
    @Test("Timestamps round to the nearest millisecond", arguments: [
        (1_790_000_000.123, "2026-09-21T14:13:20.123Z"),
        (1_790_000_000.9996, "2026-09-21T14:13:21.000Z"),
        (1_790_000_000.0004, "2026-09-21T14:13:20.000Z"),
        (-0.25, "1969-12-31T23:59:59.750Z"),
    ])
    func timestampsRoundToTheNearestMillisecond(seconds: Double, expected: String) throws {
        let date = Date(timeIntervalSince1970: seconds)
        #expect(DictationRecordCoding.timestamp(from: date) == expected)
        let parsed = try #require(DictationRecordCoding.date(fromTimestamp: expected))
        #expect(parsed == DictationRecord.millisecondPrecision(date))
    }

    @Test func readsTimestampsWithoutFractionalSeconds() throws {
        let parsed = DictationRecordCoding.date(fromTimestamp: "2026-09-21T14:13:20Z")
        #expect(parsed == Date(timeIntervalSince1970: 1_790_000_000))
        #expect(DictationRecordCoding.date(fromTimestamp: "yesterday") == nil)
    }

    /// The whole range ISO 8601 four-digit years allow reads back exactly.
    @Test(arguments: [Date.distantPast, Date.distantFuture, Date(timeIntervalSinceReferenceDate: 252_423_993_599.999)])
    func extremeButValidDatesRoundTrip(date: Date) async throws {
        defer { file.cleanUp() }
        let record = Fixtures.record("edge", createdAt: date)
        try await JSONLDictationHistory(fileURL: file.fileURL).append(record)

        #expect(try await JSONLDictationHistory(fileURL: file.fileURL).all() == [record])
    }

    /// A date the file cannot hold is refused with an error instead of crashing the app or
    /// writing a line that could never be read back.
    @Test(arguments: [
        Date(timeIntervalSinceReferenceDate: .nan),
        Date(timeIntervalSinceReferenceDate: .infinity),
        Date(timeIntervalSinceReferenceDate: -.infinity),
        Date(timeIntervalSinceReferenceDate: 252_423_993_600),
        Date(timeIntervalSinceReferenceDate: 1e16),
        Date.distantPast.addingTimeInterval(-0.001),
    ])
    func aDateTheFileCannotHoldIsAWriteError(date: Date) async throws {
        defer { file.cleanUp() }
        let history = JSONLDictationHistory(fileURL: file.fileURL)

        let error = await #expect(throws: DictationHistoryError.self) {
            try await history.append(Fixtures.record("never written", createdAt: date))
        }
        guard case .writeFailed = error else {
            Issue.record("Expected writeFailed, got \(String(describing: error))")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: file.fileURL.path))
    }

    @Test func createsTheFolderAndAFileOnlyTheUserCanRead() async throws {
        defer { file.cleanUp() }
        #expect(!FileManager.default.fileExists(atPath: file.historyFolder.path))

        try await JSONLDictationHistory(fileURL: file.fileURL).append(Fixtures.record("private", offsetMs: 0))

        #expect(try file.permissions(of: file.fileURL) == 0o600)
    }

    @Test func tightensAnExistingFileThatOthersCouldRead() async throws {
        defer { file.cleanUp() }
        try FileManager.default.createDirectory(at: file.historyFolder, withIntermediateDirectories: true)
        #expect(FileManager.default.createFile(atPath: file.fileURL.path, contents: nil, attributes: [.posixPermissions: 0o644]))

        try await JSONLDictationHistory(fileURL: file.fileURL).append(Fixtures.record("private", offsetMs: 0))

        #expect(try file.permissions(of: file.fileURL) == 0o600)
    }

    @Test func appendingAddsToTheSameFileWithoutRewritingIt() async throws {
        defer { file.cleanUp() }
        let history = JSONLDictationHistory(fileURL: file.fileURL)
        try await history.append(Fixtures.record("one", offsetMs: 0))
        let before = try file.contents()
        let inode = try file.inode()

        try await history.append(Fixtures.record("two", offsetMs: 1))

        #expect(try file.contents().starts(with: before))
        #expect(try file.inode() == inode)
    }

    @Test func readingDoesNotCreateAnything() async throws {
        defer { file.cleanUp() }
        let history = JSONLDictationHistory(fileURL: file.fileURL)

        #expect(try await history.all().isEmpty)
        #expect(try await history.recent(limit: 3).isEmpty)
        _ = try await history.prune(olderThan: Fixtures.baseDate)
        try await history.delete(id: UUID())

        #expect(!FileManager.default.fileExists(atPath: file.directory.path))
    }

    @Test func readsTensOfThousandsOfRecords() async throws {
        defer { file.cleanUp() }
        let count = 20_000
        let encoder = DictationRecordCoding.makeEncoder()
        var contents = Data()
        var records: [DictationRecord] = []
        for index in 0..<count {
            let record = Fixtures.record("dictation \(index) with some ordinary words in it", offsetMs: index)
            records.append(record)
            contents.append(try encoder.encode(record))
            contents.append(0x0A)
        }
        try FileManager.default.createDirectory(at: file.historyFolder, withIntermediateDirectories: true)
        try contents.write(to: file.fileURL)
        let history = JSONLDictationHistory(fileURL: file.fileURL)

        #expect(try await history.recent(limit: 3) == Array(records.suffix(3).reversed()))
        let all = try await history.all()
        #expect(all.count == count)
        #expect(all.first == records.last)
        #expect(all.last == records.first)
    }

    @Test func aFolderWhereTheFileShouldBeIsAReadError() async throws {
        defer { file.cleanUp() }
        try FileManager.default.createDirectory(at: file.fileURL, withIntermediateDirectories: true)
        let history = JSONLDictationHistory(fileURL: file.fileURL)

        let readError = await #expect(throws: DictationHistoryError.self) { try await history.all() }
        guard case .readFailed = readError else {
            Issue.record("Expected readFailed, got \(String(describing: readError))")
            return
        }
        let writeError = await #expect(throws: DictationHistoryError.self) {
            try await history.append(Fixtures.record("x", offsetMs: 0))
        }
        guard case .writeFailed = writeError else {
            Issue.record("Expected writeFailed, got \(String(describing: writeError))")
            return
        }
    }

    @Test func aFileWhereTheFolderShouldBeMeansTheFolderIsUnavailable() async throws {
        defer { file.cleanUp() }
        try FileManager.default.createDirectory(at: file.directory, withIntermediateDirectories: true)
        #expect(FileManager.default.createFile(atPath: file.historyFolder.path, contents: nil))
        let history = JSONLDictationHistory(fileURL: file.fileURL)

        let error = await #expect(throws: DictationHistoryError.self) {
            try await history.append(Fixtures.record("x", offsetMs: 0))
        }
        guard case .directoryUnavailable = error else {
            Issue.record("Expected directoryUnavailable, got \(String(describing: error))")
            return
        }
    }
}
