import Foundation
import Snippets
import Testing

@Suite("SnippetStore")
struct SnippetStoreTests {
    private let calendar = StoreFixtures.calendar
    private let signature = StoreFixtures.signature

    @Test func defaultURLIsInTheAppsSupportFolder() {
        let url = SnippetStore.defaultURL(
            applicationSupport: URL(fileURLWithPath: "/Users/x/Library/Application Support"),
            bundleIdentifier: "org.nerdstorm.LiveTranscribe"
        )
        #expect(url.path == "/Users/x/Library/Application Support/org.nerdstorm.LiveTranscribe/snippets.json")
    }

    @Test func aMissingFileHasNoSnippets() async throws {
        let temporary = TemporaryStore()
        defer { temporary.cleanUp() }
        #expect(try await temporary.store.all().isEmpty)
    }

    @Test func snippetsRoundTripThroughTheFile() async throws {
        let temporary = TemporaryStore()
        defer { temporary.cleanUp() }
        try await temporary.store.save([calendar, signature])

        let reopened = SnippetStore(fileURL: temporary.fileURL)
        #expect(try await reopened.all() == [calendar, signature])
    }

    @Test func anEmptyListRoundTrips() async throws {
        let temporary = TemporaryStore()
        defer { temporary.cleanUp() }
        try await temporary.store.save([calendar])
        try await temporary.store.save([])

        #expect(try await temporary.store.all().isEmpty)
        #expect(try temporary.folderContents() == ["snippets.json"])
    }

    @Test func writesPrettyPrintedJSONWithSortedKeysAndReadableURLs() async throws {
        let temporary = TemporaryStore()
        defer { temporary.cleanUp() }
        try await temporary.store.save([calendar])

        let text = try String(contentsOf: temporary.fileURL, encoding: .utf8)
        #expect(text.contains("\n  {"))
        #expect(text.contains("https://cal.example.com/alex"))
        let expansion = try #require(text.range(of: "\"expansion\""))
        let id = try #require(text.range(of: "\"id\""))
        let trigger = try #require(text.range(of: "\"trigger\""))
        #expect(expansion.lowerBound < id.lowerBound && id.lowerBound < trigger.lowerBound)
    }

    @Test func anExistingFileBecomesReadableOnlyByItsOwner() async throws {
        let temporary = TemporaryStore()
        defer { temporary.cleanUp() }
        try temporary.writeFile(Data("[]".utf8))
        try temporary.setPermissions(0o644, of: temporary.fileURL)

        try await temporary.store.save([calendar])

        #expect(try temporary.permissions(of: temporary.fileURL) == 0o600)
    }

    @Test func aNewFileAndEveryRewriteAreReadableOnlyByTheirOwner() async throws {
        let temporary = TemporaryStore()
        defer { temporary.cleanUp() }

        try await temporary.store.save([calendar])
        #expect(try temporary.permissions(of: temporary.fileURL) == 0o600)
        try await temporary.store.upsert(signature)
        #expect(try temporary.permissions(of: temporary.fileURL) == 0o600)
        try await temporary.store.delete(id: calendar.id)
        #expect(try temporary.permissions(of: temporary.fileURL) == 0o600)
    }

    @Test func leavesNoTemporaryFilesBehind() async throws {
        let temporary = TemporaryStore()
        defer { temporary.cleanUp() }
        try await temporary.store.save([calendar])
        try await temporary.store.save([calendar, signature])

        #expect(try temporary.folderContents() == ["snippets.json"])
    }

    @Test func upsertAddsNewSnippetsAndReplacesExistingOnesInPlace() async throws {
        let temporary = TemporaryStore()
        defer { temporary.cleanUp() }
        try await temporary.store.upsert(calendar)
        try await temporary.store.upsert(signature)
        var edited = calendar
        edited.expansion = "https://cal.example.com/alex/new"
        try await temporary.store.upsert(edited)

        #expect(try await temporary.store.all() == [edited, signature])
    }

    /// The edited snippet is compared with the others, not with its own old version.
    @Test func upsertCanChangeATriggersPunctuation() async throws {
        let temporary = TemporaryStore()
        defer { temporary.cleanUp() }
        try await temporary.store.save([calendar, signature])
        var edited = calendar
        edited.trigger = "My calendar-link!"
        try await temporary.store.upsert(edited)

        #expect(try await temporary.store.all() == [edited, signature])
    }

    @Test func deleteRemovesTheSnippetAndIgnoresUnknownIDs() async throws {
        let temporary = TemporaryStore()
        defer { temporary.cleanUp() }
        try await temporary.store.save([calendar, signature])

        try await temporary.store.delete(id: calendar.id)
        try await temporary.store.delete(id: calendar.id)
        try await temporary.store.delete(id: UUID())

        #expect(try await temporary.store.all() == [signature])
    }

    @Test func anInvalidSaveLeavesTheFileUntouched() async throws {
        let temporary = TemporaryStore()
        defer { temporary.cleanUp() }
        try await temporary.store.save([calendar])
        let before = try Data(contentsOf: temporary.fileURL)
        let empty = Snippet(trigger: "   ", expansion: "x")
        let sameWords = Snippet(trigger: "My calendar-link.", expansion: "other")

        await #expect(throws: SnippetError.emptyTrigger(id: empty.id)) {
            try await temporary.store.save([calendar, empty])
        }
        await #expect(throws: SnippetError.duplicateTrigger(id: sameWords.id, trigger: sameWords.trigger)) {
            try await temporary.store.upsert(sameWords)
        }
        await #expect(throws: SnippetError.duplicateID(id: calendar.id)) {
            try await temporary.store.save([calendar, Snippet(id: calendar.id, trigger: "other", expansion: "x")])
        }
        #expect(try Data(contentsOf: temporary.fileURL) == before)
    }
}
