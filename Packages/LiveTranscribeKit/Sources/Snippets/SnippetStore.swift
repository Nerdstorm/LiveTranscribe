import Foundation
import Shared

/// Keeps the user's snippets in a JSON file (an array of ``Snippet``), pretty-printed with sorted
/// keys so it diffs cleanly and can be edited by hand.
///
/// An actor so that a read-modify-write (``upsert(_:)``, ``delete(id:)``) from the settings screen
/// cannot interleave with another one. Every write replaces the file atomically with owner-only
/// permissions (0600): expansions can hold addresses and phone numbers.
///
/// A file that cannot be decoded is renamed to `snippets.json.corrupt-<timestamp>` and treated as
/// empty, so dictation keeps working and the user's text is still on disk to recover by hand.
public actor SnippetStore {
    /// Owner read and write only.
    static let filePermissions: mode_t = 0o600

    /// Where the snippets live; usually ``defaultURL(applicationSupport:bundleIdentifier:)``.
    public nonisolated let fileURL: URL
    private let now: @Sendable () -> Date

    /// A store for the file at `fileURL`. Nothing is read or created until the first call.
    public init(fileURL: URL) {
        self.init(fileURL: fileURL, now: { Date() })
    }

    /// `now` names the backup of a damaged file; tests pass a fixed clock.
    public init(fileURL: URL, now: @escaping @Sendable () -> Date) {
        self.fileURL = fileURL
        self.now = now
    }

    /// `<applicationSupport>/<bundleIdentifier>/snippets.json`, next to the app's other files.
    public static func defaultURL(applicationSupport: URL, bundleIdentifier: String) -> URL {
        applicationSupport
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("snippets.json", isDirectory: false)
    }

    /// Every stored snippet, in the order they were saved.
    ///
    /// A missing file means none have been defined yet. A file that is not valid snippet JSON is
    /// set aside (see the type's documentation) and `[]` is returned; if it cannot be set aside,
    /// this throws instead, so a later save cannot overwrite the only copy.
    public func all() throws -> [Snippet] {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        } catch {
            Log.snippets.error("Could not read the snippets file: \(error.localizedDescription, privacy: .private)")
            throw SnippetError.readFailed(error.localizedDescription)
        }

        do {
            return try JSONDecoder().decode([Snippet].self, from: data)
        } catch {
            let backup = try setAsideCorruptFile()
            Log.snippets.error(
                "Snippets file is damaged and was renamed to \(backup.lastPathComponent, privacy: .public); starting with no snippets. Decoding error: \(String(describing: error), privacy: .private)"
            )
            return []
        }
    }

    /// Replaces every stored snippet. Nothing is written unless ``Snippet/validate(_:)`` passes.
    public func save(_ snippets: [Snippet]) throws {
        do {
            try Snippet.validate(snippets)
        } catch {
            Log.snippets.notice("Snippets not saved: \(error.localizedDescription, privacy: .private)")
            throw error
        }
        try write(snippets)
    }

    /// Replaces the snippet with the same id, keeping its position, or appends a new one.
    public func upsert(_ snippet: Snippet) throws {
        var snippets = try all()
        if let index = snippets.firstIndex(where: { $0.id == snippet.id }) {
            snippets[index] = snippet
        } else {
            snippets.append(snippet)
        }
        try save(snippets)
    }

    /// Removes the snippet with this id; an unknown id is not an error, so deleting twice is safe.
    ///
    /// Removing a snippet cannot make the rest invalid, so this skips validation. That lets the
    /// user repair a hand-edited file with a duplicate trigger by deleting one of the pair. Every
    /// snippet with this id goes, so a hand-edited file that repeats an id can be repaired too.
    public func delete(id: UUID) throws {
        var snippets = try all()
        let countBefore = snippets.count
        snippets.removeAll { $0.id == id }
        guard snippets.count != countBefore else {
            Log.snippets.debug("No snippet to delete with id \(id.uuidString, privacy: .public)")
            return
        }
        try write(snippets)
    }

    // MARK: - Private

    private func write(_ snippets: [Snippet]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data: Data
        do {
            data = try encoder.encode(snippets)
        } catch {
            Log.snippets.error("Could not encode the snippets: \(error.localizedDescription, privacy: .private)")
            throw SnippetError.writeFailed(error.localizedDescription)
        }

        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try AtomicFileWriter.write(data, to: fileURL, permissions: Self.filePermissions)
        } catch {
            Log.snippets.error(
                "Could not write the snippets file at \(self.fileURL.path, privacy: .private): \(error.localizedDescription, privacy: .private)"
            )
            throw SnippetError.writeFailed(error.localizedDescription)
        }
        Log.snippets.info("Saved \(snippets.count, privacy: .public) snippets")
    }

    /// Renames the damaged file to `snippets.json.corrupt-<timestamp>` and returns the new URL.
    ///
    /// The timestamp is ISO 8601 in its basic format (`20260921T141320Z`): colons would show up
    /// as slashes in Finder. A second damaged file within the same second gets a numeric suffix.
    private func setAsideCorruptFile() throws -> URL {
        let format = Date.ISO8601FormatStyle(
            dateSeparator: .omitted,
            dateTimeSeparator: .standard,
            timeSeparator: .omitted,
            timeZone: .gmt
        )
        let baseName = "\(fileURL.lastPathComponent).corrupt-\(now().formatted(format))"
        let directory = fileURL.deletingLastPathComponent()
        var backup = directory.appendingPathComponent(baseName, isDirectory: false)
        var suffix = 2
        while FileManager.default.fileExists(atPath: backup.path) {
            backup = directory.appendingPathComponent("\(baseName)-\(suffix)", isDirectory: false)
            suffix += 1
        }

        do {
            try FileManager.default.moveItem(at: fileURL, to: backup)
            return backup
        } catch {
            Log.snippets.error(
                "Snippets file is damaged and could not be set aside: \(error.localizedDescription, privacy: .private)"
            )
            throw SnippetError.readFailed(
                "the file is damaged and could not be set aside (\(error.localizedDescription))"
            )
        }
    }
}
