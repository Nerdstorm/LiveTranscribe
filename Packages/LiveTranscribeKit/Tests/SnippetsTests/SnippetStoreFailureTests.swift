import Foundation
import Snippets
import Testing

/// Damaged, hand-edited and unwritable files: the store keeps the user's text on disk and tells
/// the caller what went wrong, instead of losing snippets silently.
@Suite("SnippetStore failures")
struct SnippetStoreFailureTests {
    private let calendar = StoreFixtures.calendar
    private let signature = StoreFixtures.signature

    @Test("A damaged file is set aside and treated as empty", arguments: [
        "[{\"trigger\": \"my link\",",
        "",
        "not json",
        "{\"trigger\": \"my link\", \"expansion\": \"x\"}",
        // A hand-added entry without an id cannot be decoded either.
        "[{\"trigger\": \"my link\", \"expansion\": \"x\"}]",
    ])
    func aDamagedFileIsSetAsideAndTreatedAsEmpty(contents: String) async throws {
        let temporary = TemporaryStore()
        defer { temporary.cleanUp() }
        let damaged = Data(contents.utf8)
        try temporary.writeFile(damaged)

        #expect(try await temporary.store.all().isEmpty)

        let backup = temporary.folder.appendingPathComponent(TemporaryStore.backupName)
        #expect(try Data(contentsOf: backup) == damaged)
        #expect(!FileManager.default.fileExists(atPath: temporary.fileURL.path))

        // The app keeps working: saving starts a fresh file next to the backup.
        try await temporary.store.save([calendar])
        #expect(try await temporary.store.all() == [calendar])
    }

    @Test func aSecondDamagedFileInTheSameSecondGetsItsOwnBackup() async throws {
        let temporary = TemporaryStore()
        defer { temporary.cleanUp() }

        try temporary.writeFile(Data("first".utf8))
        _ = try await temporary.store.all()
        try temporary.writeFile(Data("second".utf8))
        _ = try await temporary.store.all()

        #expect(try temporary.folderContents() == [TemporaryStore.backupName, TemporaryStore.backupName + "-2"])
    }

    @Test func anUnreadableFileIsAnErrorNotAnEmptyList() async throws {
        let temporary = TemporaryStore()
        defer { temporary.cleanUp() }
        // A directory where the file should be cannot be read as data, and must not be set aside.
        try FileManager.default.createDirectory(at: temporary.fileURL, withIntermediateDirectories: true)

        let error = await #expect(throws: SnippetError.self) {
            try await temporary.store.all()
        }
        #expect(SnippetError.isReadFailure(error))
        #expect(try temporary.folderContents() == ["snippets.json"])
    }

    /// Returning `[]` here would let the next save overwrite the only copy of the user's text.
    @Test(.enabled(if: TemporaryStore.honoursPermissions, "the superuser ignores folder permissions"))
    func aDamagedFileThatCannotBeSetAsideIsAnError() async throws {
        let temporary = TemporaryStore()
        defer { temporary.cleanUp() }
        let damaged = Data("not json".utf8)
        try temporary.writeFile(damaged)
        try temporary.setPermissions(0o500, of: temporary.folder)

        let error = await #expect(throws: SnippetError.self) {
            try await temporary.store.all()
        }
        #expect(SnippetError.isReadFailure(error))
        #expect(try Data(contentsOf: temporary.fileURL) == damaged)
        #expect(try temporary.folderContents() == ["snippets.json"])
    }

    @Test(.enabled(if: TemporaryStore.honoursPermissions, "the superuser ignores folder permissions"))
    func aFileThatCannotBeCreatedLeavesTheOldOneAsItWas() async throws {
        let temporary = TemporaryStore()
        defer { temporary.cleanUp() }
        try await temporary.store.save([calendar])
        let before = try Data(contentsOf: temporary.fileURL)
        try temporary.setPermissions(0o500, of: temporary.folder)

        let error = await #expect(throws: SnippetError.self) {
            try await temporary.store.save([calendar, signature])
        }
        #expect(SnippetError.isWriteFailure(error))
        #expect(try Data(contentsOf: temporary.fileURL) == before)
        #expect(try temporary.folderContents() == ["snippets.json"])
    }

    /// The temporary file is written, but cannot replace a directory: it must not be left behind.
    @Test func aFailedReplaceRemovesTheTemporaryFile() async throws {
        let temporary = TemporaryStore()
        defer { temporary.cleanUp() }
        try FileManager.default.createDirectory(at: temporary.fileURL, withIntermediateDirectories: true)

        let error = await #expect(throws: SnippetError.self) {
            try await temporary.store.save([calendar])
        }
        #expect(SnippetError.isWriteFailure(error))
        #expect(try temporary.folderContents() == ["snippets.json"])
    }

    @Test func aFolderThatCannotBeCreatedIsAWriteFailure() async throws {
        let temporary = TemporaryStore()
        defer { temporary.cleanUp() }
        // A file where the application support folder should be.
        try Data("x".utf8).write(to: temporary.root)

        let error = await #expect(throws: SnippetError.self) {
            try await temporary.store.save([calendar])
        }
        #expect(SnippetError.isWriteFailure(error))
    }

    @Test func deleteCanRepairAHandEditedFileWithADuplicateTrigger() async throws {
        let temporary = TemporaryStore()
        defer { temporary.cleanUp() }
        let duplicate = Snippet(trigger: "Sign off!", expansion: "Cheers")
        try temporary.writeFile(JSONEncoder().encode([signature, duplicate]))

        try await temporary.store.delete(id: duplicate.id)

        #expect(try await temporary.store.all() == [signature])
    }

    /// Upsert could only ever reach the first of two snippets with one id, so delete takes both.
    @Test func deleteRemovesEverySnippetWithARepeatedID() async throws {
        let temporary = TemporaryStore()
        defer { temporary.cleanUp() }
        let copy = Snippet(id: calendar.id, trigger: "other link", expansion: "x")
        try temporary.writeFile(JSONEncoder().encode([calendar, signature, copy]))

        await #expect(throws: SnippetError.duplicateID(id: calendar.id)) {
            try await temporary.store.upsert(Snippet(trigger: "new one", expansion: "y"))
        }
        try await temporary.store.delete(id: calendar.id)

        #expect(try await temporary.store.all() == [signature])
    }
}
