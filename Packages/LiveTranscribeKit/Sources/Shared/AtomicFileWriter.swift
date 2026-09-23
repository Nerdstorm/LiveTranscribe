import Darwin
import Foundation

/// Replaces a file in one step, with the permissions it must have from the moment it exists.
///
/// `Data.write(to:options: .atomic)` creates its temporary file with the default permissions and
/// leaves the caller to tighten them afterwards, so the new file is briefly readable by other
/// accounts. Here the temporary file is created with `permissions`, flushed to disk, and renamed
/// over the destination, so readers see the old file or the complete new one and nothing wider.
///
/// Every system call's `errno` is read straight after the call, inside the closure that owns the
/// path buffer: releasing that buffer may change `errno`, which would report the wrong error.
public enum AtomicFileWriter {
    /// Writes `data` to `url`, whose folder must exist. On failure the destination is unchanged
    /// and the temporary file is removed.
    public static func write(_ data: Data, to url: URL, permissions: mode_t) throws {
        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let (descriptor, openError) = temporaryURL.withUnsafeFileSystemRepresentation { path -> (Int32, Int32) in
            guard let path else { return (-1, EINVAL) }
            let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, permissions)
            return (descriptor, descriptor < 0 ? errno : 0)
        }
        guard descriptor >= 0 else { throw POSIXError(errno: openError) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            // open() applies the process umask; set the exact mode explicitly.
            guard fchmod(descriptor, permissions) == 0 else { throw POSIXError(errno: errno) }
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            try rename(temporaryURL, to: url)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    private static func rename(_ source: URL, to destination: URL) throws {
        let renameError = source.withUnsafeFileSystemRepresentation { sourcePath in
            destination.withUnsafeFileSystemRepresentation { destinationPath -> Int32 in
                guard let sourcePath, let destinationPath else { return EINVAL }
                return Darwin.rename(sourcePath, destinationPath) == 0 ? 0 : errno
            }
        }
        guard renameError == 0 else { throw POSIXError(errno: renameError) }
    }
}

private extension POSIXError {
    /// The error for an `errno` value, or a generic I/O error for a code Swift does not know.
    init(errno code: Int32) {
        self.init(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
}
