@testable import DictationUI
import Foundation
import Snippets
import Testing

/// Settings › Snippets against a real ``SnippetStore`` on a temporary file.
@Suite("SnippetListModel")
@MainActor
struct SnippetListModelTests {
    private static let fileName = "snippets.json"
    private let calendar = Snippet(trigger: "my calendar link", expansion: "https://cal.example.com/alex")
    private let signature = Snippet(trigger: "Sign off", expansion: "Best,\nAlex")
    private let address = Snippet(trigger: "address 10", expansion: "1 Main St")
    private let address2 = Snippet(trigger: "address 2", expansion: "2 Main St")

    private func makeModel(in folder: EditableListTemporaryFolder) -> (SnippetListModel, SnippetStore) {
        let store = SnippetStore(fileURL: folder.file(Self.fileName), now: { EditableListTemporaryFolder.fixedDate })
        return (SnippetListModel(store: store), store)
    }

    private func draft(trigger: String, expansion: String) -> SnippetDraft {
        var draft = SnippetDraft()
        draft.trigger = trigger
        draft.expansion = expansion
        return draft
    }

    @Test func aMissingFileLoadsAsAnEmptyList() async {
        let folder = EditableListTemporaryFolder()
        defer { folder.cleanUp() }
        let (model, _) = makeModel(in: folder)

        await model.load()

        #expect(model.status.loadState == .loaded)
        #expect(model.snippets.isEmpty)
        #expect(model.status.recoveredBackup == nil)
    }

    @Test func snippetsAreSortedByTriggerIgnoringCaseAndReadingNumbers() async throws {
        let folder = EditableListTemporaryFolder()
        defer { folder.cleanUp() }
        let (model, store) = makeModel(in: folder)
        try await store.save([signature, address, calendar, address2])

        await model.load()

        #expect(model.snippets.map(\.trigger) == ["address 2", "address 10", "my calendar link", "Sign off"])
    }

    @Test func addingASnippetTrimsTheTriggerAndKeepsTheExpansionExactly() async throws {
        let folder = EditableListTemporaryFolder()
        defer { folder.cleanUp() }
        let (model, store) = makeModel(in: folder)
        await model.load()

        let saved = await model.save(draft(trigger: "  new paragraph ", expansion: "\n\n"))

        #expect(saved)
        let stored = try await store.all()
        #expect(stored.map(\.trigger) == ["new paragraph"])
        #expect(stored.map(\.expansion) == ["\n\n"])
        #expect(model.snippets == stored)
        #expect(model.status.errorMessage == nil)
    }

    @Test func editingASnippetReplacesItInPlace() async throws {
        let folder = EditableListTemporaryFolder()
        defer { folder.cleanUp() }
        let (model, store) = makeModel(in: folder)
        try await store.save([calendar, signature])
        await model.load()

        var edit = SnippetDraft(editing: calendar)
        edit.expansion = "https://cal.example.com/alex/30min"
        #expect(model.validation(of: edit) == .valid)
        #expect(await model.save(edit))

        let stored = try await store.all()
        #expect(stored.map(\.id) == [calendar.id, signature.id])
        #expect(stored.first?.expansion == "https://cal.example.com/alex/30min")
    }

    @Test func deletingASnippetRemovesItFromTheFile() async throws {
        let folder = EditableListTemporaryFolder()
        defer { folder.cleanUp() }
        let (model, store) = makeModel(in: folder)
        try await store.save([calendar, signature])
        await model.load()

        #expect(await model.delete(id: calendar.id))

        #expect(try await store.all() == [signature])
        #expect(model.snippets == [signature])
    }

    @Test func emptyFieldsAreIncompleteNotWrong() async {
        let folder = EditableListTemporaryFolder()
        defer { folder.cleanUp() }
        let (model, _) = makeModel(in: folder)
        await model.load()

        let blank = model.validation(of: SnippetDraft())
        let noExpansion = model.validation(of: draft(trigger: "my link", expansion: ""))

        #expect(blank == .incomplete("A snippet needs a trigger phrase with at least one word."))
        #expect(noExpansion == .incomplete("A snippet needs text to insert."))
        #expect(model.validation(of: draft(trigger: "   ", expansion: "x")).canSave == false)
    }

    @Test func aTriggerWithNoWordsIsInvalid() async {
        let folder = EditableListTemporaryFolder()
        defer { folder.cleanUp() }
        let (model, _) = makeModel(in: folder)
        await model.load()

        #expect(model.validation(of: draft(trigger: "!!!", expansion: "x"))
            == .invalid("A snippet needs a trigger phrase with at least one word."))
    }

    @Test func aTriggerAnotherSnippetUsesIsInvalidButASnippetsOwnIsNot() async throws {
        let folder = EditableListTemporaryFolder()
        defer { folder.cleanUp() }
        let (model, store) = makeModel(in: folder)
        try await store.save([calendar, signature])
        await model.load()

        // Same words once case and punctuation are ignored.
        let duplicate = model.validation(of: draft(trigger: "My calendar-link.", expansion: "x"))
        var ownTrigger = SnippetDraft(editing: signature)
        ownTrigger.trigger = "sign off"

        #expect(duplicate == .invalid("Another snippet already uses the trigger \u{201C}My calendar-link.\u{201D}."))
        #expect(model.validation(of: ownTrigger) == .valid)
    }

    @Test func anInvalidDraftIsNotSavedAndTheFileIsUntouched() async throws {
        let folder = EditableListTemporaryFolder()
        defer { folder.cleanUp() }
        let (model, store) = makeModel(in: folder)
        try await store.save([calendar])
        await model.load()
        let before = folder.contents(of: Self.fileName)

        let saved = await model.save(draft(trigger: "my calendar link", expansion: "other"))

        #expect(!saved)
        #expect(folder.contents(of: Self.fileName) == before)
        #expect(model.snippets == [calendar])
        // The model refused it itself: the store was never asked, so there is no store error.
        #expect(model.status.errorMessage == nil)
    }

    @Test func aConflictAlreadyInTheFileIsNamedInsteadOfBlamingTheDraft() async throws {
        let folder = EditableListTemporaryFolder()
        defer { folder.cleanUp() }
        let (model, store) = makeModel(in: folder)
        // The list sorts lower case first, and the error names the later of the pair. Fixed ids
        // keep the order stable even if the sort ever treats the two as equal.
        let first = Snippet(id: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001")), trigger: "Sign off", expansion: "Best,\nAlex")
        let second = Snippet(id: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002")), trigger: "sign off", expansion: "Cheers")
        // Only a hand edit can store two snippets with one trigger; the store would refuse it.
        try folder.write("""
            [{"id": "\(first.id)", "trigger": "Sign off", "expansion": "Best,\\nAlex"},
             {"id": "\(second.id)", "trigger": "sign off", "expansion": "Cheers"}]
            """, to: Self.fileName)
        await model.load()
        #expect(model.snippets.count == 2)

        #expect(model.validation(of: draft(trigger: "my link", expansion: "x"))
            == .invalid("Two other snippets use the trigger \u{201C}Sign off\u{201D}. Change or delete one of them first."))

        // Editing one of the pair to a new trigger fixes the file, and is allowed.
        var fix = SnippetDraft(editing: second)
        fix.trigger = "cheers"
        #expect(model.validation(of: fix) == .valid)
        #expect(await model.save(fix))
        #expect(try await store.all().map(\.trigger).sorted() == ["Sign off", "cheers"])
    }

    @Test func aConflictAddedBehindTheScreensBackIsRefusedByTheStore() async throws {
        let folder = EditableListTemporaryFolder()
        defer { folder.cleanUp() }
        let (model, store) = makeModel(in: folder)
        await model.load()
        // Another window (or a hand edit) adds the trigger after the list was read.
        try await store.save([calendar])
        let before = folder.contents(of: Self.fileName)

        let candidate = draft(trigger: "my calendar link", expansion: "other")
        #expect(model.validation(of: candidate) == .valid)
        let saved = await model.save(candidate)

        #expect(!saved)
        #expect(model.status.errorMessage == "Another snippet already uses the trigger \u{201C}my calendar link\u{201D}.")
        #expect(folder.contents(of: Self.fileName) == before)
    }

    @Test func aDamagedFileIsSetAsideAndReported() async throws {
        let folder = EditableListTemporaryFolder()
        defer { folder.cleanUp() }
        let (model, _) = makeModel(in: folder)
        try folder.write("not json", to: Self.fileName)

        await model.load()

        let backupName = "\(Self.fileName).corrupt-\(EditableListTemporaryFolder.backupStamp)"
        #expect(model.status.loadState == .loaded)
        #expect(model.snippets.isEmpty)
        #expect(model.status.recoveredBackup?.lastPathComponent == backupName)
        #expect(try folder.names() == [backupName])
        #expect(folder.contents(of: backupName) == Data("not json".utf8))
    }

    @Test func anUnreadableFileFailsWithoutChangesUntilARetrySucceeds() async throws {
        let folder = EditableListTemporaryFolder()
        defer { folder.cleanUp() }
        let (model, _) = makeModel(in: folder)
        try folder.makeUnreadable(Self.fileName)

        await model.load()

        guard case .failed(let message) = model.status.loadState else {
            Issue.record("Expected the load to fail, got \(model.status.loadState)")
            return
        }
        #expect(message.hasPrefix("The snippets file could not be read"))
        #expect(!(await model.save(draft(trigger: "my link", expansion: "x"))))
        #expect(try folder.names() == [Self.fileName])

        try folder.makeReadable(Self.fileName)
        await model.load()
        #expect(model.status.loadState == .loaded)
    }

    @Test func previewsPutEveryLineOnOneLine() {
        #expect(SnippetExpansionPreview.text(for: "Best,\nAlex") == "Best, \u{23CE} Alex")
        #expect(SnippetExpansionPreview.text(for: "\n\n") == "\u{23CE} \u{23CE}")
        #expect(SnippetExpansionPreview.text(for: "a \t  b\r\nc") == "a b \u{23CE} c")
        #expect(SnippetExpansionPreview.text(for: "https://example.com") == "https://example.com")
    }

    @Test func previewsOfBlankOrLongExpansionsStayReadable() {
        #expect(SnippetExpansionPreview.text(for: "  \t ") == SnippetExpansionPreview.blank)
        let long = String(repeating: "word ", count: 100)
        let preview = SnippetExpansionPreview.text(for: long)
        #expect(preview.count == SnippetExpansionPreview.maximumLength + 1)
        #expect(preview.hasSuffix("\u{2026}"))
    }
}
