@testable import DictationUI
import Foundation
import Testing

/// The shared load, change and damaged-file plumbing behind every Settings list.
@Suite("EditableListStatus")
@MainActor
struct EditableListStatusTests {
    private struct Failure: LocalizedError {
        var errorDescription: String? { "The disk is full." }
    }

    @Test func startsLoadingAndCannotBeChanged() {
        let status = EditableListStatus(fileURL: URL(fileURLWithPath: "/nonexistent/list.json"), subject: "things")
        #expect(status.loadState == .loading)
        #expect(!status.canEdit)
    }

    @Test func aSuccessfulLoadAllowsChanges() async {
        let folder = EditableListTemporaryFolder()
        defer { folder.cleanUp() }
        let status = EditableListStatus(fileURL: folder.file("list.json"), subject: "things")

        let value = await status.load { 42 }

        #expect(value == 42)
        #expect(status.loadState == .loaded)
        #expect(status.canEdit)
        #expect(status.recoveredBackup == nil)
    }

    @Test func aFailedLoadKeepsTheMessageAndRefusesChanges() async {
        let folder = EditableListTemporaryFolder()
        defer { folder.cleanUp() }
        let status = EditableListStatus(fileURL: folder.file("list.json"), subject: "things")

        let value: Int? = await status.load { throw Failure() }
        var ran = false
        let performed = await status.perform("change things") { ran = true }

        #expect(value == nil)
        #expect(status.loadState == .failed("The disk is full."))
        #expect(!performed)
        #expect(!ran)
    }

    @Test func aFailedChangeKeepsTheMessageUntilTheNextChangeOrDismissal() async {
        let folder = EditableListTemporaryFolder()
        defer { folder.cleanUp() }
        let status = EditableListStatus(fileURL: folder.file("list.json"), subject: "things")
        _ = await status.load { () }

        #expect(!(await status.perform("change things") { throw Failure() }))
        #expect(status.errorMessage == "The disk is full.")
        #expect(!status.isWorking)

        #expect(await status.perform("change things") {})
        #expect(status.errorMessage == nil)

        _ = await status.perform("change things") { throw Failure() }
        status.dismissError()
        #expect(status.errorMessage == nil)
    }

    @Test func aSecondChangeIsRefusedWhileOneIsRunning() async throws {
        let folder = EditableListTemporaryFolder()
        defer { folder.cleanUp() }
        let status = EditableListStatus(fileURL: folder.file("list.json"), subject: "things")
        _ = await status.load { () }
        let gate = EditableListTestGate()

        let first = Task { await status.perform("change things") { await gate.pass() } }
        try #require(await gate.waitUntilHeld())
        #expect(status.isWorking)
        #expect(!status.canEdit)
        var secondRan = false
        let second = await status.perform("change things") { secondRan = true }
        gate.open()

        #expect(!second)
        #expect(!secondRan)
        #expect(await first.value)
        #expect(!status.isWorking)
        #expect(status.canEdit)
    }

    @Test func aReadThatOverlapsAChangeIsDroppedSoItCannotUndoTheChangeOnScreen() async throws {
        let folder = EditableListTemporaryFolder()
        defer { folder.cleanUp() }
        let status = EditableListStatus(fileURL: folder.file("list.json"), subject: "things")
        _ = await status.load { "first read" }
        let gate = EditableListTestGate()

        // The tab appears again and starts reading; the store answers with the file as it was.
        let reload = Task { await status.load { () -> String in await gate.pass(); return "before the change" } }
        try #require(await gate.waitUntilHeld())
        #expect(await status.perform("change things") {})
        gate.open()

        #expect(await reload.value == nil)
        #expect(status.loadState == .loaded)
        // A read that nothing overlapped is used as usual.
        #expect(await status.load { "after the change" } == "after the change")
    }

    @Test func aBackupThatAppearsDuringALoadIsReported() async throws {
        let folder = EditableListTemporaryFolder()
        defer { folder.cleanUp() }
        try folder.write("old", to: "list.json.corrupt-20260101T000000Z")
        let status = EditableListStatus(fileURL: folder.file("list.json"), subject: "things")

        _ = await status.load {
            try folder.write("damaged", to: "list.json.corrupt-\(EditableListTemporaryFolder.backupStamp)")
        }

        let backup = try #require(status.recoveredBackup)
        #expect(backup.lastPathComponent == "list.json.corrupt-\(EditableListTemporaryFolder.backupStamp)")
        let message = try #require(status.recoveryMessage)
        #expect(message.contains("things file was damaged"))
        #expect(message.contains(backup.lastPathComponent))

        status.dismissRecoveryNotice()
        #expect(status.recoveredBackup == nil)
        #expect(status.recoveryMessage == nil)
    }

    @Test func anOlderBackupIsNotReportedAgain() async throws {
        let folder = EditableListTemporaryFolder()
        defer { folder.cleanUp() }
        try folder.write("old", to: "list.json.corrupt-20260101T000000Z")
        let status = EditableListStatus(fileURL: folder.file("list.json"), subject: "things")

        _ = await status.load { () }

        #expect(status.recoveredBackup == nil)
    }

    @Test func theNewestOfSeveralBackupsIsTheOneReported() throws {
        let folder = EditableListTemporaryFolder()
        defer { folder.cleanUp() }
        let fileURL = folder.file("list.json")
        let before = EditableListRecovery.backups(of: fileURL)
        for suffix in ["", "-2", "-9", "-10"] {
            try folder.write("x", to: "list.json.corrupt-\(EditableListTemporaryFolder.backupStamp)\(suffix)")
        }
        try folder.write("x", to: "other.json.corrupt-\(EditableListTemporaryFolder.backupStamp)-11")

        let newest = EditableListRecovery.newBackup(of: fileURL, since: before)

        #expect(newest?.lastPathComponent == "list.json.corrupt-\(EditableListTemporaryFolder.backupStamp)-10")
    }

    @Test func aMissingFolderHasNoBackups() {
        let folder = EditableListTemporaryFolder()
        #expect(EditableListRecovery.backups(of: folder.file("list.json")).isEmpty)
    }

    @Test func validationOnlySavesWhenValid() {
        #expect(EditableListValidation.valid.canSave)
        #expect(EditableListValidation.valid.message == nil)
        #expect(!EditableListValidation.incomplete("Missing").canSave)
        #expect(EditableListValidation.incomplete("Missing").message == "Missing")
        #expect(!EditableListValidation.invalid("Wrong").canSave)
        #expect(EditableListValidation.invalid("Wrong").message == "Wrong")
    }
}
