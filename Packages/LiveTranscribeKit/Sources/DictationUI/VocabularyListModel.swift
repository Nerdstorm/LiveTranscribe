import Foundation
import Observation
import Vocabulary

/// Settings › Vocabulary: the user's terms with their spoken variants, sorted by term, and the
/// add, edit and delete actions, all through ``VocabularyStore``.
///
/// An edit is checked here first with ``VocabularyValidator``, the store's own rules, against the
/// entries on screen, so the sheet can say what is wrong as the user types. The store re-reads the
/// file and checks the whole vocabulary again before it saves an add or an edit, so a file
/// changed behind the screen's back is never overwritten with a conflict; its error is shown
/// instead.
@MainActor
@Observable
final class VocabularyListModel {
    /// Every entry as stored (tidied by the store), sorted by term.
    private(set) var entries: [VocabularyEntry] = []
    let status: EditableListStatus
    private let store: VocabularyStore

    init(store: VocabularyStore) {
        self.store = store
        status = EditableListStatus(fileURL: store.fileURL, subject: "vocabulary")
    }

    /// Reads the vocabulary from the file. A damaged file is set aside by the store and noted in
    /// ``status``; an unreadable one leaves the load state failed, with its message.
    func load() async {
        if let loaded = await status.load({ try await store.all() }) {
            entries = Self.sorted(loaded)
        }
    }

    /// The entry with `id`, if it is in the list.
    func entry(id: VocabularyEntry.ID?) -> VocabularyEntry? {
        guard let id else { return nil }
        return entries.first { $0.id == id }
    }

    /// Whether `draft` can be saved, with ``VocabularyError``'s sentence when it can't.
    ///
    /// An empty term counts as incomplete rather than wrong. The draft is checked on its own
    /// first, so its own problem is named before one elsewhere in the list; then the other
    /// entries on their own (see ``problemElsewhere(_:)``); then the draft after every other
    /// entry, which catches a term already listed and a variant another term claims. The draft
    /// replaces the entry it edits, so keeping its own term is fine.
    func validation(of draft: VocabularyDraft) -> EditableListValidation {
        let candidate = draft.entry
        if candidate.term.isEmpty {
            return .incomplete(VocabularyError.emptyTerm.localizedDescription)
        }
        let others = entries.filter { $0.id != candidate.id }
        do {
            _ = try VocabularyValidator.validated([candidate])
        } catch {
            return .invalid(error.localizedDescription)
        }
        do {
            _ = try VocabularyValidator.validated(others)
        } catch {
            return .invalid(Self.problemElsewhere(error))
        }
        do {
            _ = try VocabularyValidator.validated(others + [candidate])
            return .valid
        } catch {
            return .invalid(error.localizedDescription)
        }
    }

    /// What to say when the other entries break a rule without the draft, which only a
    /// hand-edited file can cause.
    ///
    /// The store checks the whole vocabulary before it saves, so such a problem blocks every
    /// save until it is fixed. The store's sentence for a repeated term ("… is already in your
    /// vocabulary") would read as if it were about the draft, so this names the other entries
    /// instead. Deleting one of them always works (the store's delete skips validation), and
    /// editing one works once the rest are valid without it.
    static func problemElsewhere(_ error: any Error) -> String {
        switch error as? VocabularyError {
        case .duplicateTerm(let term):
            "\u{201C}\(term)\u{201D} is in your vocabulary twice. Change or delete one of them first."
        case .conflictingVariant:
            "\(error.localizedDescription) Change one of them first."
        case .emptyTerm:
            "Another term has no word or name in it. Edit or delete it first."
        default:
            error.localizedDescription
        }
    }

    /// Adds the draft's entry, or replaces the one it edits.
    ///
    /// - Returns: Whether it was saved. When it wasn't, ``status`` holds the reason, or the draft
    ///   was not valid (see ``validation(of:)``) and nothing was attempted.
    @discardableResult
    func save(_ draft: VocabularyDraft) async -> Bool {
        guard validation(of: draft).canSave else { return false }
        let entry = draft.entry
        return await status.perform(draft.isNew ? "add a vocabulary term" : "save a vocabulary term") {
            entries = Self.sorted(try await store.upsert(entry))
        }
    }

    /// Deletes the entry with `id`. The store does not check the entries that are left, so a
    /// conflict elsewhere in a hand-edited file never blocks it.
    ///
    /// - Returns: Whether it was deleted; when it wasn't, ``status`` holds the reason.
    @discardableResult
    func delete(id: VocabularyEntry.ID) async -> Bool {
        await status.perform("delete a vocabulary term") {
            entries = Self.sorted(try await store.delete(id: id))
        }
    }

    /// Alphabetical by term, ignoring case and reading numbers as numbers; terms that compare
    /// equal (the same spelling twice in a hand-edited file) keep a fixed order.
    static func sorted(_ entries: [VocabularyEntry]) -> [VocabularyEntry] {
        entries.sorted { lhs, rhs in
            switch lhs.term.localizedStandardCompare(rhs.term) {
            case .orderedAscending: true
            case .orderedDescending: false
            case .orderedSame: lhs.id.uuidString < rhs.id.uuidString
            }
        }
    }
}
