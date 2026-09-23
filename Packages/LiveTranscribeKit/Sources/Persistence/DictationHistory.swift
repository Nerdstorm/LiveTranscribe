import Foundation

/// The local record of every dictation, kept until the user turns history off, deletes entries,
/// or sets a retention limit (decision H2). It stays on this Mac and is never synced.
///
/// "Newest first" means most recently appended first. The dictation flow appends each record as
/// the dictation finishes, so that is also `createdAt` order, and it lets a file-backed history
/// answer ``recent(limit:)`` by reading only the end of its file.
public protocol DictationHistory: Actor {
    /// Adds a record after every existing one.
    func append(_ record: DictationRecord) async throws
    /// Up to `limit` records, newest first. A `limit` of zero or less returns none.
    func recent(limit: Int) async throws -> [DictationRecord]
    /// Every record, newest first.
    func all() async throws -> [DictationRecord]
    /// Removes the record with this id. Deleting an id that is not there does nothing, so a
    /// history window racing a prune never shows an error.
    func delete(id: UUID) async throws
    /// Removes records created strictly before `cutoff`; a record created exactly at `cutoff` is
    /// kept, so "keep 30 days" keeps the dictation made exactly 30 days ago. The comparison is
    /// to the millisecond, the precision of ``DictationRecord/createdAt``. Returns how many
    /// records were removed.
    func prune(olderThan cutoff: Date) async throws -> Int
    /// Removes every record.
    func clear() async throws
}

/// Why the dictation history could not be read or changed.
public enum DictationHistoryError: LocalizedError, Equatable {
    /// The History folder could not be created.
    case directoryUnavailable(String)
    /// A dictation could not be added to the history file.
    case writeFailed(String)
    /// The history file exists but could not be read.
    case readFailed(String)
    /// Deleting, pruning or clearing could not replace the history file. The previous history
    /// is left as it was, because the file is only ever swapped in whole.
    case rewriteFailed(String)

    public var errorDescription: String? {
        switch self {
        case .directoryUnavailable(let detail): "The dictation history folder is unavailable: \(detail)"
        case .writeFailed(let detail): "Could not save the dictation to history: \(detail)"
        case .readFailed(let detail): "Could not read the dictation history: \(detail)"
        case .rewriteFailed(let detail): "Could not update the dictation history; it is unchanged: \(detail)"
        }
    }
}
