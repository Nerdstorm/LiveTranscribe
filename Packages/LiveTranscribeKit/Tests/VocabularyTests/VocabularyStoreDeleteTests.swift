import Foundation
import Testing
import Vocabulary

/// ``VocabularyStore/delete(id:)``: it removes the entry and writes, without validating the rest.
extension VocabularyStoreTests {
    @Test func deleteRemovesOnlyTheEntryWithTheId() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(in: directory)
        let first = VocabularyEntry(term: "Nerdstorm")
        let second = VocabularyEntry(term: "GitHub")
        try await store.save([first, second])

        #expect(try await store.delete(id: first.id) == [second])
        #expect(try await store.all() == [second])
    }

    /// The file is compact JSON, not the store's pretty-printed format, so a rewrite of the same
    /// entries would change its bytes.
    @Test func deletingAnUnknownIdWritesNothing() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let entry = VocabularyEntry(term: "Nerdstorm", spokenVariants: ["nerd storm"])
        let store = makeStore(in: directory)
        let handEdited = try JSONEncoder().encode([entry])
        try handEdited.write(to: store.fileURL)

        #expect(try await store.delete(id: UUID()) == [entry])
        #expect(try Data(contentsOf: store.fileURL) == handEdited)
    }

    /// A conflict left by a hand edit must not stop the user deleting an unrelated entry, like
    /// the snippet store; the entries left keep their exact text, unsanitised.
    @Test func deleteSkipsValidationSoAConflictElsewhereNeverBlocksIt() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let conflicting = [
            VocabularyEntry(term: "GitHub", spokenVariants: ["git hub"]),
            VocabularyEntry(term: " github ", spokenVariants: ["git hub", "  "]),
        ]
        let unrelated = VocabularyEntry(term: "Nerdstorm")
        let store = makeStore(in: directory)
        try JSONEncoder().encode(conflicting + [unrelated]).write(to: store.fileURL)

        #expect(try await store.delete(id: unrelated.id) == conflicting)
        #expect(try await store.all() == conflicting)

        // Deleting one of the pair repairs the file, and saving works again.
        #expect(try await store.delete(id: conflicting[1].id) == [conflicting[0]])
        #expect(try await store.upsert(unrelated) == [conflicting[0], unrelated])
    }

    @Test func deleteRemovesEveryEntryThatRepeatsTheId() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let repeated = VocabularyEntry(term: "Nerdstorm")
        let copy = VocabularyEntry(id: repeated.id, term: "Nerd Storm")
        let other = VocabularyEntry(term: "GitHub")
        let store = makeStore(in: directory)
        try JSONEncoder().encode([repeated, other, copy]).write(to: store.fileURL)

        #expect(try await store.delete(id: repeated.id) == [other])
        #expect(try await store.all() == [other])
    }

    @Test func deleteKeepsTheFileOwnerOnlyAndLeavesNoTemporaryFiles() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(in: directory)
        let first = VocabularyEntry(term: "Nerdstorm")
        try await store.save([first, VocabularyEntry(term: "GitHub")])
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.fileURL.path)

        try await store.delete(id: first.id)

        #expect(try permissions(of: store.fileURL) == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["vocabulary.json"])
    }
}
