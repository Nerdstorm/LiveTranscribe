@testable import DictationUI
import Foundation
import Shared
import Testing
import Vocabulary

/// Settings › Vocabulary against a real ``VocabularyStore`` on a temporary file.
@Suite("VocabularyListModel")
@MainActor
struct VocabularyListModelTests {
    private static let fileName = VocabularyStore.fileName
    private let nerdstorm = VocabularyEntry(term: "Nerdstorm", spokenVariants: ["nerd storm", "nerd store"])
    private let github = VocabularyEntry(term: "GitHub", spokenVariants: ["git hub"])
    private let siobhan = VocabularyEntry(term: "siobhan")

    private func makeModel(in folder: EditableListTemporaryFolder) -> (VocabularyListModel, VocabularyStore) {
        let store = VocabularyStore(fileURL: folder.file(Self.fileName), now: { EditableListTemporaryFolder.fixedDate })
        return (VocabularyListModel(store: store), store)
    }

    private func draft(term: String, variants: String = "") -> VocabularyDraft {
        var draft = VocabularyDraft()
        draft.term = term
        draft.variantsText = variants
        return draft
    }

    @Test func entriesAreSortedByTermIgnoringCase() async throws {
        let folder = EditableListTemporaryFolder()
        defer { folder.cleanUp() }
        let (model, store) = makeModel(in: folder)
        try await store.save([nerdstorm, siobhan, github])

        await model.load()

        #expect(model.status.loadState == .loaded)
        #expect(model.entries.map(\.term) == ["GitHub", "Nerdstorm", "siobhan"])
    }

    @Test func variantsAreReadOnePerLineWithoutBlanks() {
        let typed = draft(term: " Nerdstorm ", variants: "nerd storm\n\n   nerd store  \r\nnerd, storm\n")

        #expect(typed.spokenVariants == ["nerd storm", "nerd store", "nerd, storm"])
        #expect(typed.entry.term == "Nerdstorm")
        #expect(VocabularyDraft(editing: nerdstorm).variantsText == "nerd storm\nnerd store")
    }

    @Test func addingATermStoresItAsTheStoreTidiesIt() async throws {
        let folder = EditableListTemporaryFolder()
        defer { folder.cleanUp() }
        let (model, store) = makeModel(in: folder)
        await model.load()

        // A variant that is only the term again, and a repeated one, are dropped by the store.
        #expect(await model.save(draft(term: "Kubernetes", variants: "cooper netties\nkubernetes\ncooper  netties")))

        let stored = try await store.all()
        #expect(stored.map(\.term) == ["Kubernetes"])
        #expect(stored.first?.spokenVariants == ["cooper netties"])
        #expect(model.entries == stored)
    }

    @Test func editingATermReplacesItInPlace() async throws {
        let folder = EditableListTemporaryFolder()
        defer { folder.cleanUp() }
        let (model, store) = makeModel(in: folder)
        try await store.save([nerdstorm, github])
        await model.load()

        var edit = VocabularyDraft(editing: nerdstorm)
        edit.variantsText += "\nnerds dorm"
        #expect(model.validation(of: edit) == .valid)
        #expect(await model.save(edit))

        let stored = try await store.all()
        #expect(stored.map(\.id) == [nerdstorm.id, github.id])
        #expect(stored.first?.spokenVariants == ["nerd storm", "nerd store", "nerds dorm"])
    }

    @Test func deletingATermRemovesItFromTheFile() async throws {
        let folder = EditableListTemporaryFolder()
        defer { folder.cleanUp() }
        let (model, store) = makeModel(in: folder)
        try await store.save([nerdstorm, github])
        await model.load()

        #expect(await model.delete(id: github.id))

        #expect(try await store.all() == [nerdstorm])
        #expect(model.entries == [nerdstorm])
    }

    @Test func validationUsesTheStoresRules() async throws {
        let folder = EditableListTemporaryFolder()
        defer { folder.cleanUp() }
        let (model, store) = makeModel(in: folder)
        try await store.save([nerdstorm, github])
        await model.load()

        #expect(model.validation(of: VocabularyDraft()) == .incomplete(VocabularyError.emptyTerm.localizedDescription))
        #expect(model.validation(of: draft(term: "?!")) == .invalid(VocabularyError.emptyTerm.localizedDescription))
        #expect(model.validation(of: draft(term: "github"))
            == .invalid(VocabularyError.duplicateTerm("github").localizedDescription))
        #expect(model.validation(of: draft(term: "Nerdstore", variants: "nerd store"))
            == .invalid(VocabularyError.conflictingVariant(
                variant: "nerd store", firstTerm: "Nerdstorm", secondTerm: "Nerdstore"
            ).localizedDescription))
        // Changing only the casing of a term's own spelling is not a duplicate of itself.
        var recased = VocabularyDraft(editing: github)
        recased.term = "Github"
        #expect(model.validation(of: recased) == .valid)
    }

    @Test func anInvalidDraftIsNotSavedAndTheFileIsUntouched() async throws {
        let folder = EditableListTemporaryFolder()
        defer { folder.cleanUp() }
        let (model, store) = makeModel(in: folder)
        try await store.save([nerdstorm])
        await model.load()
        let before = folder.contents(of: Self.fileName)

        #expect(!(await model.save(draft(term: "NERDSTORM"))))

        #expect(folder.contents(of: Self.fileName) == before)
        #expect(model.status.errorMessage == nil)
    }

    @Test func aConflictAlreadyInTheFileIsNamedInsteadOfBlamingTheDraft() async throws {
        let folder = EditableListTemporaryFolder()
        defer { folder.cleanUp() }
        let (model, store) = makeModel(in: folder)
        // The list sorts lower case first, and the error names the later of the pair. Fixed ids
        // keep the order stable even if the sort ever treats the two as equal.
        let upper = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let lower = VocabularyEntry(id: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002")), term: "nerdstorm")
        // Only a hand edit can list one term twice; the store would refuse it.
        try folder.write("""
            [{"id": "\(upper)", "term": "Nerdstorm", "spokenVariants": ["nerd storm"]},
             {"id": "\(lower.id)", "term": "nerdstorm"}]
            """, to: Self.fileName)
        await model.load()
        #expect(model.entries.count == 2)

        #expect(model.validation(of: draft(term: "GitHub"))
            == .invalid("\u{201C}Nerdstorm\u{201D} is in your vocabulary twice. Change or delete one of them first."))

        // Editing one of the pair to a new term fixes the file, and is allowed.
        var fix = VocabularyDraft(editing: lower)
        fix.term = "Nerdstorm Labs"
        #expect(model.validation(of: fix) == .valid)
        #expect(await model.save(fix))
        #expect(try await store.all().map(\.term).sorted() == ["Nerdstorm", "Nerdstorm Labs"])
    }

    @Test func aDeleteRefusedForAConflictElsewhereSaysWhichEntriesClash() async throws {
        let folder = EditableListTemporaryFolder()
        defer { folder.cleanUp() }
        let (model, store) = makeModel(in: folder)
        let lower = VocabularyEntry(term: "nerdstorm")
        // A hand-edited file with one term twice, and an unrelated term.
        try folder.write("""
            [{"id": "\(nerdstorm.id)", "term": "Nerdstorm"},
             {"id": "\(lower.id)", "term": "nerdstorm"},
             {"id": "\(github.id)", "term": "GitHub"}]
            """, to: Self.fileName)
        await model.load()
        let before = folder.contents(of: Self.fileName)

        // The store refuses to write the two that are left with GitHub gone. It checks them in
        // file order, so it names the later spelling.
        #expect(!(await model.delete(id: github.id)))
        #expect(model.status.errorMessage
            == "\u{201C}nerdstorm\u{201D} is in your vocabulary twice. Change or delete one of them first.")
        #expect(folder.contents(of: Self.fileName) == before)

        // Deleting one of the pair fixes the file.
        #expect(await model.delete(id: lower.id))
        #expect(try await store.all().map(\.term) == ["Nerdstorm", "GitHub"])
    }

    @Test func aVariantConflictAlreadyInTheFileSaysWhichTermsClash() {
        let clash = VocabularyError.conflictingVariant(variant: "nerd storm", firstTerm: "Nerdstorm", secondTerm: "Nerdstore")

        #expect(VocabularyListModel.problemElsewhere(clash)
            == "\u{201C}nerd storm\u{201D} can\u{2019}t stand for both \u{201C}Nerdstorm\u{201D} and \u{201C}Nerdstore\u{201D}. Change one of them first.")
        #expect(VocabularyListModel.problemElsewhere(VocabularyError.emptyTerm)
            == "Another term has no word or name in it. Edit or delete it first.")
    }

    @Test func aConflictAddedBehindTheScreensBackIsRefusedByTheStore() async throws {
        let folder = EditableListTemporaryFolder()
        defer { folder.cleanUp() }
        let (model, store) = makeModel(in: folder)
        await model.load()
        try await store.save([nerdstorm])
        let before = folder.contents(of: Self.fileName)

        let candidate = draft(term: "Nerdstorm")
        #expect(model.validation(of: candidate) == .valid)
        #expect(!(await model.save(candidate)))

        #expect(model.status.errorMessage == VocabularyError.duplicateTerm("Nerdstorm").localizedDescription)
        #expect(folder.contents(of: Self.fileName) == before)
    }

    @Test func aDamagedFileIsSetAsideAndReported() async throws {
        let folder = EditableListTemporaryFolder()
        defer { folder.cleanUp() }
        let (model, _) = makeModel(in: folder)
        try folder.write("{ not json", to: Self.fileName)

        await model.load()

        let backupName = "\(Self.fileName).corrupt-\(EditableListTemporaryFolder.backupStamp)"
        #expect(model.status.loadState == .loaded)
        #expect(model.entries.isEmpty)
        #expect(model.status.recoveredBackup?.lastPathComponent == backupName)
        #expect(try folder.names() == [backupName])
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
        #expect(message.hasPrefix("Your vocabulary could not be read"))
        #expect(!(await model.save(draft(term: "Nerdstorm"))))

        try folder.makeReadable(Self.fileName)
        await model.load()
        #expect(model.status.loadState == .loaded)
    }

    @Test func thePromptLimitNoteQuotesTheLimitDictationUses() {
        let defaultLimit = AppSettings.defaults.dictation.vocabularyPromptLimit
        #expect(VocabularyPromptLimitNote.text(storedLimit: defaultLimit).contains("up to \(defaultLimit) of"))
        #expect(VocabularyPromptLimitNote.text(storedLimit: 1) == "With each dictation, cleanup is given the one most relevant term.")
        #expect(VocabularyPromptLimitNote.text(storedLimit: 0).hasPrefix("Cleanup isn\u{2019}t given any terms"))
        // Out-of-range values are clamped the way the pipeline clamps them.
        #expect(VocabularyPromptLimitNote.effectiveLimit(stored: -5) == 0)
        var huge = AppSettings.defaults.dictation
        huge.vocabularyPromptLimit = 100_000
        #expect(VocabularyPromptLimitNote.effectiveLimit(stored: 100_000) == huge.sanitized().vocabularyPromptLimit)
    }
}
