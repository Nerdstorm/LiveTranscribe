import Foundation
import Testing
import Vocabulary

@Suite("VocabularyStore")
struct VocabularyStoreTests {
    /// 2026-09-21 14:13:20 UTC.
    private static let fixedDate = Date(timeIntervalSince1970: 1_790_000_000)

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("LiveTranscribeTests-\(UUID().uuidString)")
    }

    private func makeStore(in directory: URL) -> VocabularyStore {
        VocabularyStore(fileURL: directory.appendingPathComponent("vocabulary.json"), now: { Self.fixedDate })
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require(attributes[.posixPermissions] as? Int)
    }

    @Test func defaultURLIsInTheAppsApplicationSupportFolder() {
        let applicationSupport = URL(fileURLWithPath: "/Users/someone/Library/Application Support", isDirectory: true)
        let url = VocabularyStore.defaultURL(applicationSupport: applicationSupport, bundleIdentifier: "org.nerdstorm.LiveTranscribe")
        #expect(url.path == "/Users/someone/Library/Application Support/org.nerdstorm.LiveTranscribe/vocabulary.json")
    }

    @Test func aMissingFileIsAnEmptyVocabulary() async throws {
        let directory = temporaryDirectory()
        #expect(try await makeStore(in: directory).all().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func entriesRoundTripThroughTheFile() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let entries = [
            VocabularyEntry(term: "Nerdstorm", spokenVariants: ["nerd storm", "nerd store"]),
            VocabularyEntry(term: "GitHub", spokenVariants: ["git hub"]),
            VocabularyEntry(term: "Siobhan"),
        ]
        let saved = try await makeStore(in: directory).save(entries)

        #expect(saved == entries)
        #expect(try await makeStore(in: directory).all() == entries)
    }

    @Test func savingStoresTheSanitizedEntries() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(in: directory)
        let entry = VocabularyEntry(term: "  Nerdstorm ", spokenVariants: [" nerd  storm ", "", "NERDSTORM", "nerd storm", "nerd store"])

        let saved = try await store.save([entry])

        let expected = VocabularyEntry(id: entry.id, term: "Nerdstorm", spokenVariants: ["nerd storm", "nerd store"])
        #expect(saved == [expected])
        #expect(try await store.all() == [expected])
    }

    @Test func aRejectedSaveLeavesTheFileUntouched() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(in: directory)
        let original = [VocabularyEntry(term: "GitHub")]
        try await store.save(original)

        await #expect(throws: VocabularyError.duplicateTerm("github")) {
            try await store.save([VocabularyEntry(term: "GitHub"), VocabularyEntry(term: "github")])
        }
        await #expect(throws: VocabularyError.emptyTerm) {
            try await store.upsert(VocabularyEntry(term: " "))
        }
        #expect(try await store.all() == original)
    }

    @Test func aCorruptFileIsMovedAsideAndReadsAsEmpty() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("vocabulary.json")
        let corrupt = Data("{ not json".utf8)
        try corrupt.write(to: fileURL)

        #expect(try await makeStore(in: directory).all().isEmpty)

        let backupURL = directory.appendingPathComponent("vocabulary.json.corrupt-20260921T141320Z")
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        #expect(try Data(contentsOf: backupURL) == corrupt)
    }

    @Test func aSecondCorruptFileInTheSameSecondGetsItsOwnBackup() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("vocabulary.json")
        let store = makeStore(in: directory)

        try Data("first".utf8).write(to: fileURL)
        #expect(try await store.all().isEmpty)
        try Data("[{\"term\": 1}]".utf8).write(to: fileURL)
        #expect(try await store.all().isEmpty)

        let stamp = "vocabulary.json.corrupt-20260921T141320Z"
        #expect(try Data(contentsOf: directory.appendingPathComponent(stamp)) == Data("first".utf8))
        #expect(try Data(contentsOf: directory.appendingPathComponent("\(stamp)-2")) == Data("[{\"term\": 1}]".utf8))
    }

    /// If the damaged file cannot be moved aside, reading fails rather than returning an empty
    /// vocabulary that the next save would write over the only copy of the user's entries.
    @Test func aCorruptFileThatCannotBeMovedAsideIsABackupError() async throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("vocabulary.json")
        let corrupt = Data("{ not json".utf8)
        try corrupt.write(to: fileURL)
        // Read and search only: the file stays readable but cannot be renamed.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }

        await #expect {
            try await makeStore(in: directory).all()
        } throws: { error in
            guard case .backupFailed = error as? VocabularyError else { return false }
            return true
        }
        #expect(try Data(contentsOf: fileURL) == corrupt)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["vocabulary.json"])
    }

    /// A hand-edited file may break the rules a save enforces; its entries are still used, as
    /// they are, and the next save reports the problem.
    @Test func handEditedEntriesThatBreakTheRulesAreStillRead() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let entries = [
            VocabularyEntry(term: "GitHub", spokenVariants: ["git hub"]),
            VocabularyEntry(term: "github", spokenVariants: ["git hub", "  "]),
        ]
        let store = makeStore(in: directory)
        try JSONEncoder().encode(entries).write(to: store.fileURL)

        #expect(try await store.all() == entries)
        await #expect(throws: VocabularyError.duplicateTerm("github")) {
            try await store.upsert(VocabularyEntry(term: "Nerdstorm"))
        }
        #expect(try await store.all() == entries)
    }

    @Test func aHandWrittenEntryWithoutVariantsIsRead() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = makeStore(in: directory)
        let json = #"[{"id": "6F9619FF-8B86-D011-B42D-00C04FC964FF", "term": "Siobhan"}]"#
        try Data(json.utf8).write(to: store.fileURL)

        let entries = try await store.all()
        #expect(entries.map(\.term) == ["Siobhan"])
        #expect(entries.first?.spokenVariants == [])
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["vocabulary.json"])
    }

    @Test func theFileIsReadableByTheOwnerOnly() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(in: directory)
        try await store.save([VocabularyEntry(term: "Siobhan")])
        #expect(try permissions(of: store.fileURL) == 0o600)

        // Rewriting a file whose permissions were widened restores them.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.fileURL.path)
        try await store.upsert(VocabularyEntry(term: "GitHub"))
        #expect(try permissions(of: store.fileURL) == 0o600)
    }

    @Test func savingLeavesNoTemporaryFilesBehind() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(in: directory)
        try await store.save([VocabularyEntry(term: "GitHub")])
        try await store.save([VocabularyEntry(term: "GitHub"), VocabularyEntry(term: "Nerdstorm")])
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["vocabulary.json"])
    }

    @Test func theFileIsAJSONArrayOfEntries() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(in: directory)
        try await store.save([VocabularyEntry(term: "Nerdstorm", spokenVariants: ["nerd storm"])])

        let array = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [[String: Any]])
        #expect(array.count == 1)
        #expect(array.first?["term"] as? String == "Nerdstorm")
        #expect(array.first?["spokenVariants"] as? [String] == ["nerd storm"])
    }

    @Test func upsertAddsNewEntriesAndReplacesExistingOnesInPlace() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(in: directory)
        var first = VocabularyEntry(term: "Nerdstorm")
        let second = VocabularyEntry(term: "GitHub")
        try await store.upsert(first)
        try await store.upsert(second)

        first.spokenVariants = ["nerd storm"]
        let stored = try await store.upsert(first)

        #expect(stored == [first, second])
        #expect(try await store.all() == [first, second])
    }

    @Test func deleteRemovesOnlyTheEntryWithTheId() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(in: directory)
        let first = VocabularyEntry(term: "Nerdstorm")
        let second = VocabularyEntry(term: "GitHub")
        try await store.save([first, second])

        #expect(try await store.delete(id: first.id) == [second])
        #expect(try await store.delete(id: UUID()) == [second])
        #expect(try await store.all() == [second])
    }

    @Test func anUnreadableFileIsAReadError() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(in: directory)
        // A folder where the file should be cannot be read as data.
        try FileManager.default.createDirectory(at: store.fileURL, withIntermediateDirectories: true)

        await #expect {
            try await store.all()
        } throws: { error in
            guard case .readFailed = error as? VocabularyError else { return false }
            return true
        }
    }

    @Test func anUnwritableLocationIsAWriteError() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // A regular file where the folder should be.
        let blocker = directory.appendingPathComponent("blocker")
        try Data().write(to: blocker)
        let store = VocabularyStore(fileURL: blocker.appendingPathComponent("vocabulary.json"), now: { Self.fixedDate })

        await #expect {
            try await store.save([VocabularyEntry(term: "GitHub")])
        } throws: { error in
            guard case .writeFailed = error as? VocabularyError else { return false }
            return true
        }
    }
}
