import Foundation

/// Finds the copy of a damaged file that a store set aside.
///
/// The snippets, vocabulary and per-app settings stores all rename a file they cannot decode to
/// `<file name>.corrupt-<timestamp>` (with `-2`, `-3`, … for more in the same second) and then
/// read as empty, without telling the caller. Comparing the folder's backups before and after a
/// store call is how Settings learns that it happened and can say where the user's text went.
enum EditableListRecovery {
    /// The names of every backup of `fileURL` in its folder; empty when the folder can't be listed
    /// (it usually doesn't exist yet).
    static func backups(of fileURL: URL) -> Set<String> {
        let prefix = fileURL.lastPathComponent + ".corrupt-"
        let folder = fileURL.deletingLastPathComponent()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        return Set(names.filter { $0.hasPrefix(prefix) })
    }

    /// The newest backup of `fileURL` that is not in `before`, or `nil` when none appeared.
    ///
    /// Names are compared numerically, so `-10` counts as newer than `-9`.
    static func newBackup(of fileURL: URL, since before: Set<String>) -> URL? {
        let added = backups(of: fileURL).subtracting(before)
        guard let newest = added.max(by: { $0.localizedStandardCompare($1) == .orderedAscending }) else {
            return nil
        }
        return fileURL.deletingLastPathComponent().appendingPathComponent(newest, isDirectory: false)
    }
}
