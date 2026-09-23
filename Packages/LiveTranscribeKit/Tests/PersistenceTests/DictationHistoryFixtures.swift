import Foundation
@testable import Persistence

/// Records and histories shared by the dictation history tests.
enum DictationHistoryFixtures {
    /// A fixed, whole-second instant, so expected timestamps can be written out in full.
    static let baseDate = Date(timeIntervalSince1970: 1_790_000_000)

    static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("LiveTranscribeTests-\(UUID().uuidString)")
    }

    /// A record `offsetMs` milliseconds after ``baseDate``.
    static func record(_ text: String, offsetMs: Int = 0, id: UUID = UUID()) -> DictationRecord {
        record(text, createdAt: baseDate.addingTimeInterval(Double(offsetMs) / 1000), id: id)
    }

    /// A record created at exactly `createdAt` (before the record rounds it to the millisecond).
    static func record(_ text: String, createdAt: Date, id: UUID = UUID()) -> DictationRecord {
        DictationRecord(
            id: id,
            createdAt: createdAt,
            appName: "TextEdit",
            bundleIdentifier: "com.apple.TextEdit",
            rawText: text,
            cleanedText: text.capitalized,
            cleanupLevel: "medium",
            fellBack: false,
            fallbackReason: nil,
            delivery: "accessibility",
            audioDurationMs: 2_400,
            latencyMs: 380
        )
    }
}

/// Every ``DictationHistory`` must behave the same, so the shared tests run against each.
enum HistoryBackend: String, CaseIterable, CustomStringConvertible {
    case memory
    case jsonLines
    /// The file-backed history reading a few bytes at a time, so every line crosses a chunk
    /// boundary.
    case jsonLinesInTinyChunks

    var description: String { rawValue }

    func make() -> HistoryUnderTest {
        switch self {
        case .memory:
            return HistoryUnderTest(history: MemoryDictationHistory(), directory: nil)
        case .jsonLines:
            let directory = DictationHistoryFixtures.temporaryDirectory()
            let url = directory.appendingPathComponent("dictations.jsonl")
            return HistoryUnderTest(history: JSONLDictationHistory(fileURL: url), directory: directory)
        case .jsonLinesInTinyChunks:
            let directory = DictationHistoryFixtures.temporaryDirectory()
            let url = directory.appendingPathComponent("dictations.jsonl")
            return HistoryUnderTest(history: JSONLDictationHistory(fileURL: url, readChunkSize: 7), directory: directory)
        }
    }
}

/// A history and the folder to delete after the test, if it has one.
struct HistoryUnderTest {
    let history: any DictationHistory
    let directory: URL?

    func cleanUp() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }
}

/// A history file in its own temporary folder, with helpers to look at and tamper with the file
/// directly, as a crash or a hand edit would.
struct HistoryFileFixture {
    let directory = DictationHistoryFixtures.temporaryDirectory()
    var fileURL: URL { directory.appendingPathComponent("History/dictations.jsonl") }
    var historyFolder: URL { fileURL.deletingLastPathComponent() }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }

    func lines() throws -> [String] {
        try String(contentsOf: fileURL, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    func contents() throws -> Data {
        try Data(contentsOf: fileURL)
    }

    func permissions(of url: URL) throws -> Int? {
        try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    }

    /// The file's inode number: it changes when the file is replaced rather than written to.
    func inode() throws -> Int? {
        try FileManager.default.attributesOfItem(atPath: fileURL.path)[.systemFileNumber] as? Int
    }

    func setFolderPermissions(_ permissions: Int) throws {
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: historyFolder.path)
    }

    /// Writes bytes straight to the end of the file, bypassing the history.
    func appendRaw(_ text: String) throws {
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }
}
