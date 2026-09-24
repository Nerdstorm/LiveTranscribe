import Foundation
import Insertion
import os
import Testing

/// ``AppOverridesStore/update(_:)``: read, change and write as one step on the store.
extension AppOverridesStoreTests {
    @Test func updateChangesOnlyWhatTheClosureChanges() async throws {
        let folder = TemporaryFolder()
        let store = AppOverridesStore(fileURL: folder.fileURL)
        try await store.save(AppOverrides(methods: ["com.apple.Notes": .paste, "com.apple.Terminal": .accessibility]))

        let updated = try await store.update { overrides in
            overrides.methods["com.apple.Notes"] = nil
            overrides.methods["com.barebones.bbedit"] = .paste
        }

        let expected = AppOverrides(methods: ["com.apple.Terminal": .accessibility, "com.barebones.bbedit": .paste])
        #expect(updated == expected)
        #expect(try await store.load() == expected)
        #expect(try folder.contents() == [AppOverridesStore.fileName])
    }

    @Test func updateStartsFromNothingWhenTheFileIsMissing() async throws {
        let folder = TemporaryFolder()
        let store = AppOverridesStore(fileURL: folder.fileURL)

        try await store.update { $0.methods["com.apple.Notes"] = .paste }

        #expect(try await store.load() == AppOverrides(methods: ["com.apple.Notes": .paste]))
        let attributes = try FileManager.default.attributesOfItem(atPath: folder.fileURL.path)
        #expect(attributes[.posixPermissions] as? Int == 0o600)
    }

    /// Like ``AppOverridesStore/load()``: the damaged file is kept for the user, and the
    /// change is applied to an empty list rather than written over it.
    @Test func updateSetsACorruptFileAsideBeforeWriting() async throws {
        let folder = TemporaryFolder()
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: folder.fileURL)
        let store = AppOverridesStore(fileURL: folder.fileURL, now: { Self.fixedNow })

        let updated = try await store.update { $0.methods["com.apple.Notes"] = .paste }

        #expect(updated == AppOverrides(methods: ["com.apple.Notes": .paste]))
        #expect(try folder.contents() == [Self.corruptName, AppOverridesStore.fileName].sorted())
        #expect(try Data(contentsOf: folder.url.appendingPathComponent(Self.corruptName)) == Data("not json".utf8))
    }

    /// A change that changes nothing leaves the file alone, so an entry this version skipped
    /// (an unknown method) is not dropped by, say, removing an app that has no setting.
    @Test func anUpdateThatChangesNothingWritesNothing() async throws {
        let folder = TemporaryFolder()
        let store = AppOverridesStore(fileURL: folder.fileURL)
        #expect(try await store.update { $0.methods["com.apple.Notes"] = nil } == .empty)
        #expect(!FileManager.default.fileExists(atPath: folder.url.path))

        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        let handEdited = Data(#"{"methods":{"com.apple.Notes":"type","com.google.Chrome":"paste"}}"#.utf8)
        try handEdited.write(to: folder.fileURL)

        #expect(try await store.update { $0.methods["com.apple.Terminal"] = nil }.methods == ["com.google.Chrome": .paste])
        #expect(try Data(contentsOf: folder.fileURL) == handEdited)
    }

    @Test func anUnreadableFileFailsTheUpdateWithoutCallingTheChange() async throws {
        let folder = TemporaryFolder()
        // A folder where the file should be: it exists but cannot be read as data.
        try FileManager.default.createDirectory(at: folder.fileURL, withIntermediateDirectories: true)
        let store = AppOverridesStore(fileURL: folder.fileURL)
        let calls = OSAllocatedUnfairLock(initialState: 0)

        await #expect {
            try await store.update { _ in calls.withLock { $0 += 1 } }
        } throws: { error in
            guard case .readFailed = error as? AppOverridesStoreError else { return false }
            return true
        }
        #expect(calls.withLock { $0 } == 0)
        #expect(try folder.contents() == [AppOverridesStore.fileName])
    }

    /// The file reads fine but the folder is read-only, so only the write can fail.
    @Test(.enabled(if: getuid() != 0, "root ignores the read-only folder"))
    func aFailedWriteFailsTheUpdateAndKeepsTheFile() async throws {
        let folder = TemporaryFolder()
        let store = AppOverridesStore(fileURL: folder.fileURL)
        try await store.save(AppOverrides(methods: ["com.apple.Terminal": .accessibility]))
        let before = try Data(contentsOf: folder.fileURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.url.path) }

        await #expect {
            try await store.update { $0.methods["com.apple.Notes"] = .paste }
        } throws: { error in
            guard case .writeFailed = error as? AppOverridesStoreError else { return false }
            return true
        }
        #expect(try Data(contentsOf: folder.fileURL) == before)
        #expect(try folder.contents() == [AppOverridesStore.fileName])
    }

    /// Changes started together from many tasks all land: none reads a copy another is about
    /// to replace.
    @Test func concurrentUpdatesAreNeverLost() async throws {
        let folder = TemporaryFolder()
        let store = AppOverridesStore(fileURL: folder.fileURL)
        let identifiers = (0..<24).map { "org.example.App\($0)" }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for identifier in identifiers {
                group.addTask { try await store.update { $0.methods[identifier] = .paste } }
            }
            try await group.waitForAll()
        }

        #expect(try await store.load().methods.keys.sorted() == identifiers.sorted())
    }
}
