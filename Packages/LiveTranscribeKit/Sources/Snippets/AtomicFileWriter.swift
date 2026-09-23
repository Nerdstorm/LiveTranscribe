import Foundation

/// Replaces a file in one step with a new one that has the given permissions from the moment it
/// is created.
///
/// `Data.write(options: .atomic)` creates its temporary file with the default permissions (0644
/// under the usual umask) and cannot be told otherwise, so private text would be readable by
/// other accounts until a later `chmod`. Here the temporary file is created with `open(2)` and
/// the final mode, flushed, and renamed over the destination, which is atomic on one volume.
///
/// `open(2)` masks the mode with the process umask, which can only remove bits; `fchmod(2)` then
/// sets it exactly, so an unusual umask cannot leave the file unreadable by its own owner.
enum AtomicFileWriter {
    enum Failure: LocalizedError, Equatable {
        case createTemporaryFile(String)
        case writeTemporaryFile(String)
        case replaceFile(String)

        var errorDescription: String? {
            switch self {
            case .createTemporaryFile(let reason): "could not create a temporary file (\(reason))"
            case .writeTemporaryFile(let reason): "could not write the temporary file (\(reason))"
            case .replaceFile(let reason): "could not replace the file (\(reason))"
            }
        }
    }

    /// Writes `data` to `url`, whose directory must exist. Throws ``Failure``; on failure the
    /// destination is unchanged and the temporary file is removed.
    static func write(_ data: Data, to url: URL, permissions: mode_t) throws {
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp", isDirectory: false)

        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, permissions)
        guard descriptor >= 0 else {
            throw Failure.createTemporaryFile(currentErrnoDescription())
        }
        guard fchmod(descriptor, permissions) == 0 else {
            let reason = currentErrnoDescription()
            close(descriptor)
            unlink(temporary.path)
            throw Failure.createTemporaryFile(reason)
        }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            unlink(temporary.path)
            throw Failure.writeTemporaryFile(error.localizedDescription)
        }

        guard rename(temporary.path, url.path) == 0 else {
            let reason = currentErrnoDescription()
            unlink(temporary.path)
            throw Failure.replaceFile(reason)
        }
    }

    /// The message for `errno`; read it straight after the failing call.
    private static func currentErrnoDescription() -> String {
        String(cString: strerror(errno))
    }
}
