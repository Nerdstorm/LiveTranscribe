import Foundation
import Shared

/// The user's vocabulary, stored as a JSON array in `vocabulary.json`.
///
/// The file is the only copy: every call reads or writes it, so edits made in Settings reach the
/// next dictation without any cache to invalidate, and the file is small enough that this costs
/// nothing noticeable. Writes are atomic and the file is readable by the owner only (0600),
/// because the names people add are often other people's names.
///
/// A file that cannot be decoded is renamed to `vocabulary.json.corrupt-<timestamp>` (an ISO 8601
/// basic-format UTC time, which has no colons, so it is a valid file name everywhere) and the
/// vocabulary starts empty, so a damaged file never blocks dictation and is never overwritten.
public actor VocabularyStore {
    public static let fileName = "vocabulary.json"

    /// Owner read and write only.
    static let filePermissions: mode_t = 0o600

    public nonisolated let fileURL: URL
    private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - fileURL: Where the vocabulary lives; see ``defaultURL(applicationSupport:bundleIdentifier:)``.
    ///   - now: The clock used to name the backup of a corrupt file. Tests pass a fixed date.
    public init(fileURL: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.fileURL = fileURL
        self.now = now
    }

    /// `<applicationSupport>/<bundleIdentifier>/vocabulary.json`, next to the other settings files.
    public static func defaultURL(applicationSupport: URL, bundleIdentifier: String) -> URL {
        applicationSupport
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    /// Every entry, in the order the user added them. A missing file is an empty vocabulary; a
    /// corrupt one is moved aside and also reads as empty.
    ///
    /// - Throws: ``VocabularyError/readFailed(_:)`` when the file exists but cannot be read, and
    ///   ``VocabularyError/backupFailed(_:)`` when a corrupt file cannot be moved aside.
    public func all() throws -> [VocabularyEntry] {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return []
        } catch {
            Log.vocabulary.error("Could not read the vocabulary file: \(error.localizedDescription, privacy: .private)")
            throw VocabularyError.readFailed(error.localizedDescription)
        }

        let entries: [VocabularyEntry]
        do {
            entries = try JSONDecoder().decode([VocabularyEntry].self, from: data)
        } catch {
            try moveCorruptFileAside(decodingError: error)
            return []
        }
        // A hand-edited file may break the rules Settings enforces. The replacer copes (the first
        // entry wins), so the entries are still used; the next save reports the problem.
        do {
            _ = try VocabularyValidator.validated(entries)
        } catch {
            Log.vocabulary.notice("The vocabulary file has conflicting entries: \(error.localizedDescription, privacy: .private)")
        }
        return entries
    }

    /// Replaces the whole vocabulary with `entries`, sanitised (see
    /// ``VocabularyEntry/sanitized()``).
    ///
    /// - Returns: The entries as stored, so callers can show the sanitised spelling.
    /// - Throws: A ``VocabularyError`` from validation, in which case the file is untouched, or
    ///   ``VocabularyError/writeFailed(_:)``.
    @discardableResult
    public func save(_ entries: [VocabularyEntry]) throws -> [VocabularyEntry] {
        let validated: [VocabularyEntry]
        do {
            validated = try VocabularyValidator.validated(entries)
        } catch {
            Log.vocabulary.info("Vocabulary not saved: \(error.localizedDescription, privacy: .private)")
            throw error
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(validated)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try AtomicFileWriter.write(data, to: fileURL, permissions: Self.filePermissions)
        } catch {
            Log.vocabulary.error("Could not save the vocabulary: \(error.localizedDescription, privacy: .private)")
            throw VocabularyError.writeFailed(error.localizedDescription)
        }
        Log.vocabulary.info("Saved \(validated.count, privacy: .public) vocabulary entries")
        return validated
    }

    /// Adds `entry`, or replaces the entry with the same id in place.
    ///
    /// - Returns: The whole vocabulary as stored.
    @discardableResult
    public func upsert(_ entry: VocabularyEntry) throws -> [VocabularyEntry] {
        var entries = try all()
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
        return try save(entries)
    }

    /// Removes the entry with `id`. Removing an entry that is not there changes nothing.
    ///
    /// - Returns: The whole vocabulary as stored.
    @discardableResult
    public func delete(id: UUID) throws -> [VocabularyEntry] {
        var entries = try all()
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            Log.vocabulary.debug("No vocabulary entry to delete with id \(id.uuidString, privacy: .public)")
            return entries
        }
        entries.remove(at: index)
        return try save(entries)
    }

    private func moveCorruptFileAside(decodingError: Error) throws {
        let stamp = now().formatted(
            Date.ISO8601FormatStyle(dateSeparator: .omitted, timeSeparator: .omitted, timeZone: .gmt)
        )
        let directory = fileURL.deletingLastPathComponent()
        let baseName = "\(fileURL.lastPathComponent).corrupt-\(stamp)"
        var backupURL = directory.appendingPathComponent(baseName, isDirectory: false)
        var attempt = 2
        while FileManager.default.fileExists(atPath: backupURL.path) {
            backupURL = directory.appendingPathComponent("\(baseName)-\(attempt)", isDirectory: false)
            attempt += 1
        }
        do {
            try FileManager.default.moveItem(at: fileURL, to: backupURL)
        } catch {
            Log.vocabulary.error(
                "The vocabulary file is corrupt and could not be moved aside: \(error.localizedDescription, privacy: .private)"
            )
            throw VocabularyError.backupFailed(error.localizedDescription)
        }
        Log.vocabulary.error(
            "The vocabulary file is corrupt; moved it to \(backupURL.lastPathComponent, privacy: .public) and started empty: \(String(describing: decodingError), privacy: .private)"
        )
    }
}
