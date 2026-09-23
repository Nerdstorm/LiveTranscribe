import Foundation
@testable import Persistence
import Testing

/// The file-backed history with a damaged file (a crash mid-write, a hand edit), and what delete,
/// prune and clear do to the file, including when they cannot change it.
@Suite("JSONLDictationHistory rewrites")
struct JSONLDictationHistoryRewriteTests {
    private typealias Fixtures = DictationHistoryFixtures
    private let file = HistoryFileFixture()

    @Test func unreadableLinesAreSkippedAndTheRestStillReads() async throws {
        defer { file.cleanUp() }
        let history = JSONLDictationHistory(fileURL: file.fileURL)
        let older = Fixtures.record("older", offsetMs: 0)
        let newer = Fixtures.record("newer", offsetMs: 1)
        try await history.append(older)
        try file.appendRaw("this is not json\n{\"id\":\"missing every other field\"}\n")
        try await history.append(newer)
        try file.appendRaw("{\"half\":\"a line cut short")

        #expect(try await history.all() == [newer, older])
        #expect(try await history.recent(limit: 1) == [newer])
        #expect(try await history.recent(limit: 2) == [newer, older])
    }

    /// A crash mid-append leaves a line without its newline; the next append must not glue its
    /// record onto that fragment.
    @Test func anAppendAfterATornLineStartsOnANewLine() async throws {
        defer { file.cleanUp() }
        let history = JSONLDictationHistory(fileURL: file.fileURL)
        let before = Fixtures.record("before the crash", offsetMs: 0)
        let after = Fixtures.record("after the crash", offsetMs: 1)
        try await history.append(before)
        try file.appendRaw("{\"id\":\"torn")

        try await history.append(after)

        #expect(try await history.all() == [after, before])
        #expect(try file.lines().count == 3)
    }

    /// Unreadable lines cannot be dated, so prune drops them rather than keeping user text past
    /// the retention limit; the count it returns is of records only.
    @Test func pruneDropsUnreadableLines() async throws {
        defer { file.cleanUp() }
        let history = JSONLDictationHistory(fileURL: file.fileURL)
        let old = Fixtures.record("old", offsetMs: 0)
        let kept = Fixtures.record("kept", offsetMs: 60_000)
        try await history.append(old)
        try file.appendRaw("garbage\n")
        try await history.append(kept)

        #expect(try await history.prune(olderThan: Fixtures.baseDate.addingTimeInterval(1)) == 1)

        #expect(try await history.all() == [kept])
        #expect(try file.lines().count == 1)
    }

    @Test func pruneDropsUnreadableLinesEvenWhenNoRecordIsOld() async throws {
        defer { file.cleanUp() }
        let history = JSONLDictationHistory(fileURL: file.fileURL)
        let kept = Fixtures.record("kept", offsetMs: 60_000)
        try await history.append(kept)
        try file.appendRaw("{\"id\":\"torn")

        #expect(try await history.prune(olderThan: Fixtures.baseDate) == 0)

        #expect(try file.lines().count == 1)
        #expect(try await history.all() == [kept])
    }

    /// Deleting one entry removes that entry only. A line this build cannot read (possibly a
    /// record from a newer build) is copied over byte for byte.
    @Test func deleteKeepsUnreadableLines() async throws {
        defer { file.cleanUp() }
        let history = JSONLDictationHistory(fileURL: file.fileURL)
        let doomed = Fixtures.record("delete me", offsetMs: 0)
        let kept = Fixtures.record("keep me", offsetMs: 1)
        let unreadable = "{\"id\":\"from a newer build\",\"createdAt\":42}"
        try await history.append(doomed)
        try file.appendRaw(unreadable + "\n")
        try await history.append(kept)

        try await history.delete(id: doomed.id)

        #expect(try await history.all() == [kept])
        let lines = try file.lines()
        #expect(lines.count == 2)
        #expect(lines.first == unreadable)
    }

    /// Nothing to remove means nothing is written: same bytes, same file.
    @Test func deletingAnUnknownIDLeavesTheFileUntouched() async throws {
        defer { file.cleanUp() }
        let history = JSONLDictationHistory(fileURL: file.fileURL)
        try await history.append(Fixtures.record("only", offsetMs: 0))
        try file.appendRaw("garbage\n")
        let before = try file.contents()
        let inode = try file.inode()

        try await history.delete(id: UUID())

        #expect(try file.contents() == before)
        #expect(try file.inode() == inode)
    }

    @Test func aRewriteKeepsTheFileOnlyReadableByTheUser() async throws {
        defer { file.cleanUp() }
        let history = JSONLDictationHistory(fileURL: file.fileURL)
        let doomed = Fixtures.record("delete me", offsetMs: 0)
        try await history.append(doomed)
        try await history.append(Fixtures.record("keep me", offsetMs: 1))

        try await history.delete(id: doomed.id)

        #expect(try file.permissions(of: file.fileURL) == 0o600)
        #expect(try file.lines().count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: file.historyFolder.path) == ["dictations.jsonl"])
    }

    @Test func clearDeletesTheFileAndAnyLeftoverRewrite() async throws {
        defer { file.cleanUp() }
        let history = JSONLDictationHistory(fileURL: file.fileURL)
        try await history.append(Fixtures.record("secret", offsetMs: 0))
        let leftover = file.historyFolder.appendingPathComponent(".dictations.jsonl.crashed.tmp")
        #expect(FileManager.default.createFile(atPath: leftover.path, contents: Data("secret\n".utf8)))

        try await history.clear()

        #expect(!FileManager.default.fileExists(atPath: file.fileURL.path))
        #expect(!FileManager.default.fileExists(atPath: leftover.path))
    }

    /// When the folder cannot be written, delete, prune and clear report ``DictationHistoryError/rewriteFailed(_:)``
    /// and the history is exactly as it was.
    @Test(.enabled(if: geteuid() != 0, "Folder permissions do not stop root"))
    func aRewriteThatCannotWriteFailsAndLeavesTheHistoryAsItWas() async throws {
        defer { file.cleanUp() }
        let history = JSONLDictationHistory(fileURL: file.fileURL)
        let old = Fixtures.record("old", offsetMs: 0)
        let new = Fixtures.record("new", offsetMs: 60_000)
        try await history.append(old)
        try await history.append(new)
        let before = try file.contents()
        try file.setFolderPermissions(0o500)
        defer { try? file.setFolderPermissions(0o700) }

        let operations: [(String, @Sendable () async throws -> Void)] = [
            ("delete", { try await history.delete(id: old.id) }),
            ("prune", { _ = try await history.prune(olderThan: Fixtures.baseDate.addingTimeInterval(1)) }),
            ("clear", { try await history.clear() }),
        ]
        for (name, operation) in operations {
            let error = await #expect(throws: DictationHistoryError.self, "\(name)") { try await operation() }
            guard case .rewriteFailed = error else {
                Issue.record("Expected rewriteFailed from \(name), got \(String(describing: error))")
                continue
            }
        }

        #expect(try file.contents() == before)
        #expect(try await history.all() == [new, old])
    }
}
