import Foundation
import Observation
import Shared

/// Where an editable Settings list's file stands, and the last thing that went wrong with it.
///
/// The snippets, vocabulary and per-app settings lists each own one. Their models run every
/// store call through ``load(_:)`` or ``perform(_:_:)``, so all three report an unreadable file,
/// a failed save and a damaged file the same way, and ``EditableListPane`` shows them the same way.
@MainActor
@Observable
final class EditableListStatus {
    /// Whether the list has been read from its file.
    enum LoadState: Equatable {
        /// The first read has not finished.
        case loading
        case loaded
        /// The file could not be read. The message is shown with a Retry button, and nothing can
        /// be changed until a read succeeds, so a save can never replace a file nobody has seen.
        case failed(String)
    }

    private(set) var loadState: LoadState = .loading
    /// Why the last change was not saved, as a sentence for the screen. Cleared when the next
    /// change starts, or by ``dismissError()``.
    private(set) var errorMessage: String?
    /// Where the store put a damaged file it set aside, so the screen can say where the text went.
    private(set) var recoveredBackup: URL?
    /// A change is being written; controls that would start another one are disabled.
    private(set) var isWorking = false
    /// How many changes have started, so a read that overlaps one can tell its copy is older than
    /// what the change wrote.
    @ObservationIgnored private var changesStarted = 0

    /// The file the store keeps the list in, watched for backups of a damaged copy.
    let fileURL: URL
    /// What the list holds, as the notices name its file ("snippets", "vocabulary").
    let subject: String

    /// - Parameters:
    ///   - fileURL: The store's file.
    ///   - subject: What the list holds, for the notices and the log.
    init(fileURL: URL, subject: String) {
        self.fileURL = fileURL
        self.subject = subject
    }

    var isLoaded: Bool { loadState == .loaded }

    /// Whether the list can be changed now: it has been read, and no other change is being written.
    var canEdit: Bool { isLoaded && !isWorking }

    /// A sentence about the damaged file the store set aside, for the notice above the list.
    var recoveryMessage: String? {
        guard let recoveredBackup else { return nil }
        return "The \(subject) file was damaged, so it was renamed to \u{201C}\(recoveredBackup.lastPathComponent)\u{201D} and the list starts empty. What it held is still in that file."
    }

    /// Reads the list with `read`.
    ///
    /// A list that was already on screen stays there while it is read again. The tab reads its
    /// file each time it appears, so a change can start while such a read is still waiting for
    /// the store; the read may then have seen the file from before the change.
    ///
    /// - Returns: What `read` returned. `nil` when it threw, and ``loadState`` then holds the
    ///   message; also `nil` when a change started during the read, because that change re-reads
    ///   the list itself and the read's copy may be older.
    func load<Value>(_ read: @MainActor () async throws -> Value) async -> Value? {
        if !isLoaded { loadState = .loading }
        let backupsBefore = EditableListRecovery.backups(of: fileURL)
        let changesBefore = changesStarted
        do {
            let value = try await read()
            noteRecovery(since: backupsBefore)
            loadState = .loaded
            guard changesStarted == changesBefore else {
                Log.ui.debug("Dropped a read of the \(self.subject, privacy: .public) that overlapped a change")
                return nil
            }
            return value
        } catch {
            Log.ui.error("Could not load the \(self.subject, privacy: .public): \(error.localizedDescription, privacy: .private)")
            loadState = .failed(error.localizedDescription)
            return nil
        }
    }

    /// Runs one change to the list: an add, an edit or a delete.
    ///
    /// Refused (returns `false` without running `change`) until the list has been read, and
    /// while another change is being written.
    ///
    /// - Parameter action: What the change does, for the log ("save a snippet").
    /// - Returns: Whether `change` finished without throwing. When it threw, ``errorMessage``
    ///   holds the store's sentence.
    @discardableResult
    func perform(_ action: String, _ change: @MainActor () async throws -> Void) async -> Bool {
        guard canEdit else {
            Log.ui.notice("Did not \(action, privacy: .public): the \(self.subject, privacy: .public) file has not been read, or another change is running")
            return false
        }
        isWorking = true
        changesStarted += 1
        errorMessage = nil
        defer { isWorking = false }
        // The stores re-read the file before changing it, so a change can find it damaged too.
        let backupsBefore = EditableListRecovery.backups(of: fileURL)
        do {
            try await change()
            noteRecovery(since: backupsBefore)
            return true
        } catch {
            noteRecovery(since: backupsBefore)
            Log.ui.error("Could not \(action, privacy: .public): \(error.localizedDescription, privacy: .private)")
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Hides the last change's error.
    func dismissError() {
        errorMessage = nil
    }

    /// Hides the notice about a damaged file; the backup itself stays where it is.
    func dismissRecoveryNotice() {
        recoveredBackup = nil
    }

    private func noteRecovery(since backupsBefore: Set<String>) {
        guard let backup = EditableListRecovery.newBackup(of: fileURL, since: backupsBefore) else { return }
        Log.ui.notice("The \(self.subject, privacy: .public) file was damaged and set aside as \(backup.lastPathComponent, privacy: .public)")
        recoveredBackup = backup
    }
}
