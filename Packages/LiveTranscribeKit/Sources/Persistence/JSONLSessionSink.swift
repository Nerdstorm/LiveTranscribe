import Foundation
import Shared

/// Appends one JSON line per segment to `<directory>/<sessionID>.jsonl`.
///
/// Each write is followed by `synchronize()`, so a crash loses at most the segment being written.
public actor JSONLSessionSink: SessionSink {
    public nonisolated let location: URL?
    private var handle: FileHandle?
    private let encoder: JSONEncoder

    public init(directory: URL, sessionID: UUID) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("\(sessionID.uuidString).jsonl")
        guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
            throw PersistenceError.cannotCreateFile(fileURL.path)
        }
        self.handle = try FileHandle(forWritingTo: fileURL)
        self.location = fileURL
        self.encoder = Self.makeEncoder()
        Log.persistence.info("Session file created: \(fileURL.lastPathComponent, privacy: .public)")
    }

    public func append(_ record: SegmentRecord) throws {
        guard let handle else { throw PersistenceError.closed }
        var line = try encoder.encode(record)
        line.append(0x0A)
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
        try handle.synchronize()
    }

    public func close() throws {
        guard let handle else { return }
        self.handle = nil
        try handle.synchronize()
        try handle.close()
    }

    /// Reads every record of a session file (for tests, the bench and tooling).
    public static func readRecords(at url: URL) throws -> [SegmentRecord] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let contents = try String(contentsOf: url, encoding: .utf8)
        return try contents
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { try decoder.decode(SegmentRecord.self, from: Data($0.utf8)) }
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
