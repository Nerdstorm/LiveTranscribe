import Foundation
import Shared

/// Why the user's per-app insertion overrides could not be read or saved.
public enum AppOverridesStoreError: LocalizedError, Equatable, Sendable {
    /// Application Support could not be located or created.
    case directoryUnavailable(String)
    /// The file exists but could not be read (permissions, I/O), or it is corrupt and could not
    /// be set aside. It is left untouched either way.
    case readFailed(String)
    /// The overrides could not be written. The previous file, if any, is intact.
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .directoryUnavailable(let detail):
            "The Application Support folder is unavailable: \(detail)"
        case .readFailed(let detail):
            "The per-app insertion settings could not be read: \(detail)"
        case .writeFailed(let detail):
            "The per-app insertion settings could not be saved: \(detail)"
        }
    }
}

/// Loads and saves the user's per-app insertion overrides as JSON.
///
/// The file holds only the user's entries; the bundled defaults live in code, so an update can
/// change them without a migration. Combine with ``AppOverrides/merged(with:)``.
///
/// An actor so a save from Settings and a load at launch never interleave on the file. A change
/// to some entries goes through ``update(_:)``, which reads, changes and writes in one step.
public actor AppOverridesStore {
    public static let fileName = "insertion-overrides.json"
    /// Owner read and write only, like the other files the user edits in Settings.
    static let filePermissions: mode_t = 0o600

    public nonisolated let fileURL: URL
    private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - fileURL: Usually ``defaultFileURL(bundleIdentifier:)``; tests pass a temporary file.
    ///   - now: The clock used to name a corrupt file when it is set aside.
    public init(fileURL: URL, now: @escaping @Sendable () -> Date = Date.init) {
        self.fileURL = fileURL
        self.now = now
    }

    /// `~/Library/Application Support/<bundle id>/insertion-overrides.json`.
    public static func defaultFileURL(bundleIdentifier: String) throws(AppOverridesStoreError) -> URL {
        do {
            let applicationSupport = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            )
            return applicationSupport
                .appendingPathComponent(bundleIdentifier, isDirectory: true)
                .appendingPathComponent(fileName, isDirectory: false)
        } catch {
            throw .directoryUnavailable(error.localizedDescription)
        }
    }

    /// The user's overrides. A missing file means none.
    ///
    /// A file that is not valid overrides JSON is renamed to
    /// `insertion-overrides.json.corrupt-<ISO 8601 time>` and treated as empty, so one bad edit
    /// neither blocks dictation nor is silently overwritten by the next save. If it cannot be
    /// renamed, this throws ``AppOverridesStoreError/readFailed(_:)`` instead.
    public func load() throws(AppOverridesStoreError) -> AppOverrides {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .empty
        } catch {
            Log.insertion.error("""
                Overrides unreadable at \(self.fileURL.path, privacy: .private): \
                \(error.localizedDescription, privacy: .private)
                """)
            throw .readFailed(error.localizedDescription)
        }

        let overrides: AppOverrides
        do {
            overrides = try JSONDecoder().decode(AppOverrides.self, from: data)
        } catch {
            let backup = try setAsideCorruptFile()
            Log.insertion.error("""
                Per-app insertion overrides were corrupt; set aside as \(backup.lastPathComponent, privacy: .public) \
                and started empty: \(String(describing: error), privacy: .private)
                """)
            return .empty
        }
        Log.insertion.info("Loaded \(overrides.methods.count, privacy: .public) per-app insertion overrides")
        return overrides
    }

    /// Replaces the file with `overrides` (the user's entries only), atomically, so a crash
    /// mid-write leaves the previous file.
    public func save(_ overrides: AppOverrides) throws(AppOverridesStoreError) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            let data = try encoder.encode(overrides)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try AtomicFileWriter.write(data, to: fileURL, permissions: Self.filePermissions)
            Log.insertion.info("Saved \(overrides.methods.count, privacy: .public) per-app insertion overrides")
        } catch {
            Log.insertion.error("""
                Overrides not saved to \(self.fileURL.path, privacy: .private): \
                \(error.localizedDescription, privacy: .private)
                """)
            throw .writeFailed(error.localizedDescription)
        }
    }

    /// Reads the file, applies `change` to the user's overrides, and saves the result, as one
    /// step on the actor: no other load, save or update can run in between, so a change made
    /// elsewhere is never lost to a stale copy.
    ///
    /// Reading works as in ``load()``: a missing file starts empty, and a corrupt one is set
    /// aside first. When `change` leaves the overrides as they were, nothing is written.
    ///
    /// - Returns: The overrides as they now are.
    /// - Throws: ``AppOverridesStoreError/readFailed(_:)`` from the read, in which case
    ///   `change` is not called and the file is untouched, or
    ///   ``AppOverridesStoreError/writeFailed(_:)``.
    @discardableResult
    public func update(
        _ change: @Sendable (inout AppOverrides) -> Void
    ) throws(AppOverridesStoreError) -> AppOverrides {
        let current = try load()
        var updated = current
        change(&updated)
        guard updated != current else {
            Log.insertion.debug("Per-app insertion overrides unchanged; nothing written")
            return current
        }
        try save(updated)
        return updated
    }

    /// Renames the damaged file to `insertion-overrides.json.corrupt-<timestamp>` and returns the
    /// new URL.
    ///
    /// The timestamp is ISO 8601 in its basic format (`20260921T141320Z`): colons would show up as
    /// slashes in Finder. A second damaged file within the same second gets a numeric suffix, so an
    /// earlier backup is never replaced.
    private func setAsideCorruptFile() throws(AppOverridesStoreError) -> URL {
        let stamp = now().formatted(
            Date.ISO8601FormatStyle(dateSeparator: .omitted, timeSeparator: .omitted, timeZone: .gmt)
        )
        let directory = fileURL.deletingLastPathComponent()
        let baseName = "\(fileURL.lastPathComponent).corrupt-\(stamp)"
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
            Log.insertion.error("""
                Per-app insertion overrides are corrupt and could not be set aside: \
                \(error.localizedDescription, privacy: .private)
                """)
            throw .readFailed("the file is damaged and could not be set aside (\(error.localizedDescription))")
        }
    }
}
