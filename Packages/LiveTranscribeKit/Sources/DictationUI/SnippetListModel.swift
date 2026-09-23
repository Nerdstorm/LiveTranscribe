import Foundation
import Observation
import Snippets

/// Settings › Snippets: the user's snippets, sorted by trigger, and the add, edit and delete
/// actions, all through ``SnippetStore``.
///
/// An edit is checked here first, against the snippets on screen, so the sheet can say what is
/// wrong as the user types. The store re-reads the file and checks the whole list again before it
/// writes anything, so a file changed behind the screen's back is never overwritten with a
/// conflict; its error is shown instead.
@MainActor
@Observable
final class SnippetListModel {
    /// Every snippet, sorted by trigger.
    private(set) var snippets: [Snippet] = []
    let status: EditableListStatus
    private let store: SnippetStore

    init(store: SnippetStore) {
        self.store = store
        status = EditableListStatus(fileURL: store.fileURL, subject: "snippets")
    }

    /// Reads the snippets from the file. A damaged file is set aside by the store and noted in
    /// ``status``; an unreadable one leaves the load state failed, with its message.
    func load() async {
        if let loaded = await status.load({ try await store.all() }) {
            snippets = Self.sorted(loaded)
        }
    }

    /// The snippet with `id`, if it is in the list.
    func snippet(id: Snippet.ID?) -> Snippet? {
        guard let id else { return nil }
        return snippets.first { $0.id == id }
    }

    /// Whether `draft` can be saved, with ``SnippetError``'s sentence when it can't.
    ///
    /// Empty fields count as incomplete rather than wrong. The draft is checked on its own first,
    /// so its own problem is named before one elsewhere in the list; then the other snippets on
    /// their own (see ``problemElsewhere(_:)``); then all of them together, which catches a
    /// trigger that is already used. The draft replaces the snippet it edits, so keeping its own
    /// trigger is fine.
    func validation(of draft: SnippetDraft) -> EditableListValidation {
        let candidate = draft.snippet
        if candidate.trigger.isEmpty {
            return .incomplete(SnippetError.emptyTrigger(id: candidate.id).localizedDescription)
        }
        if candidate.expansion.isEmpty {
            return .incomplete(SnippetError.emptyExpansion(id: candidate.id).localizedDescription)
        }
        let others = snippets.filter { $0.id != candidate.id }
        do {
            try Snippet.validate([candidate])
        } catch {
            return .invalid(error.localizedDescription)
        }
        do {
            try Snippet.validate(others)
        } catch {
            return .invalid(Self.problemElsewhere(error))
        }
        do {
            try Snippet.validate(others + [candidate])
            return .valid
        } catch {
            return .invalid(error.localizedDescription)
        }
    }

    /// What to say when the other snippets break a rule without the draft, which only a
    /// hand-edited file can cause.
    ///
    /// The store checks the whole list before it writes, so such a problem blocks every save until
    /// it is fixed. The store's own sentence would read as if it were about the draft ("Another
    /// snippet already uses the trigger …" while the user types a different one), so this names
    /// the other snippets instead. Deleting one of them always works (the store's delete skips
    /// validation), and editing one works once the rest are valid without it.
    static func problemElsewhere(_ error: any Error) -> String {
        switch error as? SnippetError {
        case .duplicateTrigger(_, let trigger):
            "Two other snippets use the trigger \u{201C}\(trigger)\u{201D}. Change or delete one of them first."
        case .emptyTrigger:
            "Another snippet has no trigger phrase. Edit or delete it first."
        case .emptyExpansion:
            "Another snippet has no text to insert. Edit or delete it first."
        default:
            // A shared id: the store's sentence already says it is about the file.
            error.localizedDescription
        }
    }

    /// Adds the draft's snippet, or replaces the one it edits.
    ///
    /// - Returns: Whether it was saved. When it wasn't, ``status`` holds the reason, or the draft
    ///   was not valid (see ``validation(of:)``) and nothing was attempted.
    @discardableResult
    func save(_ draft: SnippetDraft) async -> Bool {
        guard validation(of: draft).canSave else { return false }
        let snippet = draft.snippet
        return await status.perform(draft.isNew ? "add a snippet" : "save a snippet") {
            try await store.upsert(snippet)
            snippets = Self.sorted(try await store.all())
        }
    }

    /// Deletes the snippet with `id`.
    ///
    /// - Returns: Whether it was deleted; when it wasn't, ``status`` holds the reason.
    @discardableResult
    func delete(id: Snippet.ID) async -> Bool {
        await status.perform("delete a snippet") {
            try await store.delete(id: id)
            snippets = Self.sorted(try await store.all())
        }
    }

    /// Alphabetical by trigger, ignoring case and reading numbers as numbers ("item 2" before
    /// "item 10"); snippets with the same trigger text keep a fixed order.
    static func sorted(_ snippets: [Snippet]) -> [Snippet] {
        snippets.sorted { lhs, rhs in
            switch lhs.trigger.localizedStandardCompare(rhs.trigger) {
            case .orderedAscending: true
            case .orderedDescending: false
            case .orderedSame: lhs.id.uuidString < rhs.id.uuidString
            }
        }
    }
}
