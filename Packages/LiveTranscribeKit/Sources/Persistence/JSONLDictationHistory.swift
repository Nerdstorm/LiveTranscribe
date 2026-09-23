import Foundation
import Shared

/// Dictation history as JSON Lines: one ``DictationRecord`` per line, oldest first.
///
/// - Appending adds one line with a single write and never rewrites the file, so saving a
///   dictation costs the same however long the history is. The folder is created on the first
///   append, and the file is kept at 0600 because it holds what the user said.
/// - ``recent(limit:)`` reads the file backwards and decodes only as many lines as it returns.
///   ``all()`` streams the whole file, which stays fast for tens of thousands of records.
/// - A line that cannot be read (cut short by a crash, or edited by hand) is skipped and logged
///   without its content; the rest of the history still reads.
/// - ``delete(id:)`` and ``prune(olderThan:)`` write a new file and swap it in whole, so a crash
///   leaves either the old history or the new one. They rewrite only when something is removed.
///   ``clear()`` deletes the file. After a swap or a delete the folder is flushed as well, so a
///   removal survives a power cut instead of bringing deleted dictations back.
/// - A record whose `createdAt` is outside the years 1 to 9999 (or not a real date) is refused
///   with ``DictationHistoryError/writeFailed(_:)``, never written as a line that cannot be read.
/// - Unreadable lines: ``prune(olderThan:)`` drops them, because they cannot be dated and keeping
///   them would hold user text past the retention limit. ``delete(id:)`` keeps them, so deleting
///   one entry never removes anything else (such as records written by a newer build).
/// - `createdAt` is kept to the millisecond, the precision of ``DictationRecord/createdAt``.
///
/// Use one instance per file: the actor is what keeps a rewrite from racing an append.
/// Nothing here touches the network: history never leaves this Mac.
public actor JSONLDictationHistory: DictationHistory {
    /// Bytes per read. Large enough that a typical history reads in a few calls; it affects only
    /// I/O granularity, never results, which is why it is not a setting.
    static let readChunkSize = 64 * 1024

    public nonisolated let fileURL: URL
    private let file: LineFile
    private let encoder = DictationRecordCoding.makeEncoder()
    private let decoder = DictationRecordCoding.makeDecoder()

    /// File I/O blocks, so the actor runs on its own serial queue instead of occupying a
    /// cooperative-pool thread while a large history is read or rewritten.
    private let queue = DispatchSerialQueue(label: "LiveTranscribe.DictationHistory", qos: .userInitiated)
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    /// Creates a history backed by `fileURL`. Nothing is created on disk until the first append.
    public init(fileURL: URL) {
        self.init(fileURL: fileURL, readChunkSize: Self.readChunkSize)
    }

    /// For tests: a small `readChunkSize` makes every line cross a chunk boundary.
    init(fileURL: URL, readChunkSize: Int) {
        self.fileURL = fileURL
        self.file = LineFile(url: fileURL, chunkSize: readChunkSize)
    }

    /// `<applicationSupport>/<bundleIdentifier>/History/dictations.jsonl`.
    public static func defaultURL(applicationSupport: URL, bundleIdentifier: String) -> URL {
        applicationSupport
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("History", isDirectory: true)
            .appendingPathComponent("dictations.jsonl", isDirectory: false)
    }

    // MARK: - DictationHistory

    public func append(_ record: DictationRecord) throws {
        let line: Data
        do {
            line = try encoder.encode(record)
        } catch {
            Log.persistence.error("Dictation history: could not encode a record: \(error.localizedDescription, privacy: .private)")
            throw DictationHistoryError.writeFailed(error.localizedDescription)
        }
        try createDirectory()
        do {
            try file.append(line)
        } catch {
            Log.persistence.error("Dictation history: append failed: \(error.localizedDescription, privacy: .private)")
            throw DictationHistoryError.writeFailed(error.localizedDescription)
        }
    }

    public func recent(limit: Int) throws -> [DictationRecord] {
        guard limit > 0 else { return [] }
        return try readNewestFirst(limit: limit)
    }

    public func all() throws -> [DictationRecord] {
        try readNewestFirst(limit: nil)
    }

    /// Removes that record only; unreadable lines are copied over unchanged.
    public func delete(id: UUID) throws {
        let removed = try rewrite(during: "delete", dropUnreadable: false) { $0.id != id }
        if removed == 0 {
            Log.persistence.debug("Dictation history: nothing to delete for \(id.uuidString, privacy: .public)")
        }
    }

    /// Removes records created before `cutoff`, and unreadable lines, which cannot be dated.
    /// The returned count is of records only.
    public func prune(olderThan cutoff: Date) throws -> Int {
        try rewrite(during: "prune", dropUnreadable: true) { !$0.isPruned(olderThan: cutoff) }
    }

    public func clear() throws {
        do {
            try file.remove()
            Log.persistence.info("Dictation history cleared")
        } catch {
            Log.persistence.error("Dictation history: clear failed: \(error.localizedDescription, privacy: .private)")
            throw DictationHistoryError.rewriteFailed(error.localizedDescription)
        }
    }

    // MARK: - Reading

    private func readNewestFirst(limit: Int?) throws -> [DictationRecord] {
        var records: [DictationRecord] = []
        var unreadable = UnreadableLines()
        do {
            try file.forEachLineReversed { line in
                do {
                    records.append(try decoder.decode(DictationRecord.self, from: line))
                } catch {
                    unreadable.record(error)
                }
                return limit.map { records.count < $0 } ?? true
            }
        } catch {
            Log.persistence.error("Dictation history: read failed: \(error.localizedDescription, privacy: .private)")
            throw DictationHistoryError.readFailed(error.localizedDescription)
        }
        unreadable.log(during: "read")
        return records
    }

    // MARK: - Rewriting

    /// Keeps the records `keep` accepts and drops the rest, and unreadable lines too when
    /// `dropUnreadable` is set. Returns how many records were dropped.
    ///
    /// The first pass only reads, so the common case of nothing to drop never writes. The second
    /// copies kept lines byte for byte, so records are not re-encoded. Line numbers from the
    /// first pass stay valid in the second because the actor runs nothing else in between.
    private func rewrite(
        during operation: String,
        dropUnreadable: Bool,
        keeping keep: (DictationRecord) -> Bool
    ) throws -> Int {
        var dropped = IndexSet()
        var removed = 0
        var unreadable = UnreadableLines()
        do {
            var index = 0
            try file.forEachLine { line in
                defer { index += 1 }
                do {
                    if !keep(try decoder.decode(DictationRecord.self, from: line)) {
                        dropped.insert(index)
                        removed += 1
                    }
                } catch {
                    unreadable.record(error)
                    if dropUnreadable { dropped.insert(index) }
                }
                return true
            }
            guard !dropped.isEmpty else {
                unreadable.log(during: operation)
                return 0
            }

            try file.replace { write in
                var index = 0
                try file.forEachLine { line in
                    defer { index += 1 }
                    if !dropped.contains(index) { try write(line) }
                    return true
                }
            }
        } catch {
            Log.persistence.error("Dictation history: \(operation, privacy: .public) failed: \(error.localizedDescription, privacy: .private)")
            throw DictationHistoryError.rewriteFailed(error.localizedDescription)
        }
        unreadable.log(during: operation)
        let droppedLines = dropped.count - removed
        Log.persistence.info(
            "Dictation history: \(operation, privacy: .public) removed \(removed, privacy: .public) record(s) and \(droppedLines, privacy: .public) unreadable line(s)"
        )
        return removed
    }

    private func createDirectory() throws {
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            Log.persistence.error("Dictation history: could not create its folder: \(error.localizedDescription, privacy: .private)")
            throw DictationHistoryError.directoryUnavailable(error.localizedDescription)
        }
    }
}
