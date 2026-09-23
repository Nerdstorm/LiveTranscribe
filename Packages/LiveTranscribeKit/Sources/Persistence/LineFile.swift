import Foundation
import Shared

/// Newline-delimited file access for ``JSONLDictationHistory``.
///
/// Reads stream the file in chunks, forwards or backwards, so neither the whole file nor more
/// lines than the caller wants are held in memory. Nothing is cached between calls: a file that
/// was replaced or deleted from outside is seen as it is at the next call.
///
/// Every file this type creates, including the temporary file of a rewrite, is readable and
/// writable by the user only (0600), because it holds what the user said.
struct LineFile: Sendable {
    static let permissions: mode_t = 0o600
    private static let newline: UInt8 = 0x0A

    let url: URL
    /// Bytes per read or buffered write. It changes how often the disk is touched, never the
    /// result; tests use a few bytes to cross chunk boundaries everywhere.
    let chunkSize: Int

    init(url: URL, chunkSize: Int) {
        precondition(chunkSize > 0, "chunkSize must be positive")
        self.url = url
        self.chunkSize = chunkSize
    }

    // MARK: - Reading

    /// Calls `body` with each non-empty line, first to last, until it returns `false`.
    /// A missing file has no lines. A last line without a newline is still passed on.
    func forEachLine(_ body: (Data) throws -> Bool) throws {
        guard let handle = try openForReading() else { return }
        defer { try? handle.close() }
        var pending = Data()
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            pending.append(chunk)
            var lineStart = pending.startIndex
            while let newline = pending[lineStart...].firstIndex(of: Self.newline) {
                if newline > lineStart, try !body(pending.subdata(in: lineStart..<newline)) { return }
                lineStart = newline + 1
            }
            pending = pending.subdata(in: lineStart..<pending.endIndex)
        }
        if !pending.isEmpty { _ = try body(pending) }
    }

    /// Calls `body` with each non-empty line, last to first, until it returns `false`, reading
    /// the file backwards so the newest lines cost the same however long the file is.
    func forEachLineReversed(_ body: (Data) throws -> Bool) throws {
        guard let handle = try openForReading() else { return }
        defer { try? handle.close() }
        var position = try handle.seekToEnd()
        // The bytes of the line that ends where the previous chunk began.
        var carry = Data()
        while position > 0 {
            let size = min(UInt64(chunkSize), position)
            position -= size
            try handle.seek(toOffset: position)
            guard var buffer = try handle.read(upToCount: Int(size)), buffer.count == Int(size) else {
                throw POSIXError(.EIO)
            }
            buffer.append(carry)
            var lineEnd = buffer.endIndex
            while let newline = buffer[buffer.startIndex..<lineEnd].lastIndex(of: Self.newline) {
                if lineEnd > newline + 1, try !body(buffer.subdata(in: (newline + 1)..<lineEnd)) { return }
                lineEnd = newline
            }
            carry = buffer.subdata(in: buffer.startIndex..<lineEnd)
        }
        if !carry.isEmpty { _ = try body(carry) }
    }

    // MARK: - Writing

    /// Appends `line` and a newline with a single write, creating the file if needed, and waits
    /// until it is on disk.
    ///
    /// If the file does not end in a newline (a write cut short by a crash), a newline goes first
    /// so the torn line stays on its own and does not swallow this one.
    func append(_ line: Data) throws {
        let handle = try open(url, flags: O_RDWR | O_CREAT | O_APPEND)
        defer { try? handle.close() }
        try restrictPermissions(of: handle)
        let end = try handle.seekToEnd()
        var bytes = Data(capacity: line.count + 2)
        if end > 0 {
            try handle.seek(toOffset: end - 1)
            if try handle.read(upToCount: 1)?.first != Self.newline {
                bytes.append(Self.newline)
            }
        }
        bytes.append(line)
        bytes.append(Self.newline)
        // O_APPEND puts the write at the end whatever the read above left the offset at.
        try handle.write(contentsOf: bytes)
        try handle.synchronize()
    }

    /// Replaces the file with the lines `produce` writes, atomically: the new content goes to a
    /// temporary file beside it, which is flushed and then renamed over the original. Readers
    /// and a crash see the old file or the new one, never a mix; on failure the old file stays.
    func replace(_ produce: (_ write: (Data) throws -> Void) throws -> Void) throws {
        removeStaleTemporaryFiles()
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent("\(temporaryPrefix)\(UUID().uuidString).tmp", isDirectory: false)
        let handle = try open(temporary, flags: O_WRONLY | O_CREAT | O_EXCL)
        do {
            try restrictPermissions(of: handle)
            var buffer = Data()
            try produce { line in
                buffer.append(line)
                buffer.append(Self.newline)
                if buffer.count >= chunkSize {
                    try handle.write(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            try handle.write(contentsOf: buffer)
            try handle.synchronize()
            try handle.close()
            let renamed = Self.posixCall(temporary) { source in
                url.withUnsafeFileSystemRepresentation { destination in
                    guard let destination else {
                        errno = ENAMETOOLONG
                        return -1
                    }
                    return rename(source, destination)
                }
            }
            guard renamed.result == 0 else { throw Self.posixError(renamed.errno) }
        } catch {
            // Closing twice is harmless: FileHandle closes its descriptor only once.
            try? handle.close()
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        synchronizeDirectory()
    }

    /// Deletes the file and any temporary file a crashed rewrite left behind. A missing file is
    /// not an error.
    func remove() throws {
        removeStaleTemporaryFiles()
        let removed = Self.posixCall(url) { unlink($0) }
        guard removed.result == 0 || removed.errno == ENOENT else { throw Self.posixError(removed.errno) }
        if removed.result == 0 { synchronizeDirectory() }
    }

    // MARK: - Helpers

    /// Temporary files are hidden and named after the file, so they are easy to find and remove.
    private var temporaryPrefix: String { ".\(url.lastPathComponent)." }

    /// A rewrite interrupted by a crash leaves its temporary file, which holds user text; removing
    /// it keeps "Clear history" and retention honest.
    private func removeStaleTemporaryFiles() {
        let directory = url.deletingLastPathComponent()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
        else { return }
        for name in names where name.hasPrefix(temporaryPrefix) && name.hasSuffix(".tmp") {
            do {
                try FileManager.default.removeItem(at: directory.appendingPathComponent(name, isDirectory: false))
                Log.persistence.notice("Removed a temporary history file left by an interrupted rewrite")
            } catch {
                Log.persistence.error("Could not remove a stale temporary history file: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    /// Flushes the folder itself after a rename or unlink. Without it a power loss can undo a
    /// completed delete, prune or clear and bring removed dictations back. The change has already
    /// happened by then, so a failure is logged rather than reported as a failed operation.
    private func synchronizeDirectory() {
        let directory = url.deletingLastPathComponent()
        let opened = Self.posixCall(directory) { Darwin.open($0, O_RDONLY | O_CLOEXEC) }
        guard opened.result >= 0 else {
            Log.persistence.error("Could not open the history folder to flush it: errno \(opened.errno, privacy: .public)")
            return
        }
        defer { Darwin.close(opened.result) }
        if fsync(opened.result) != 0 {
            let code = errno
            Log.persistence.error("Could not flush the history folder: errno \(code, privacy: .public)")
        }
    }

    /// Opens the file for reading, or returns `nil` when it does not exist yet.
    private func openForReading() throws -> FileHandle? {
        do {
            return try open(url, flags: O_RDONLY)
        } catch let error as POSIXError where error.code == .ENOENT {
            return nil
        }
    }

    /// Opens with `open(2)` so a new file is created with ``permissions`` from the start rather
    /// than being briefly readable by others. Anything but a regular file (a folder in its place,
    /// say) is an error rather than an empty history.
    private func open(_ url: URL, flags: Int32) throws -> FileHandle {
        let opened = Self.posixCall(url) { Darwin.open($0, flags | O_CLOEXEC, Self.permissions) }
        guard opened.result >= 0 else { throw Self.posixError(opened.errno) }
        let handle = FileHandle(fileDescriptor: opened.result, closeOnDealloc: true)
        var info = stat()
        guard fstat(opened.result, &info) == 0 else { throw Self.posixError(errno) }
        guard info.st_mode & S_IFMT == S_IFREG else { throw POSIXError(.EFTYPE) }
        return handle
    }

    /// Sets 0600 even on a file that already existed with wider permissions (created by an older
    /// build, or restored from a backup), so user text never stays readable by others.
    private func restrictPermissions(of handle: FileHandle) throws {
        guard fchmod(handle.fileDescriptor, Self.permissions) == 0 else { throw Self.posixError(errno) }
    }

    /// Runs a POSIX call on the URL's file-system path and captures `errno` straight away,
    /// before any other call can overwrite it.
    private static func posixCall(_ url: URL, _ call: (UnsafePointer<CChar>) -> Int32) -> (result: Int32, errno: Int32) {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return (-1, ENAMETOOLONG) }
            let result = call(path)
            return (result, errno)
        }
    }

    private static func posixError(_ code: Int32) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
}
