import Shared
import SwiftUI
import Vocabulary

/// Settings › Vocabulary: names and jargon the user wants spelled their way, with the ways
/// speech-to-text mishears them. Edits `vocabulary.json` through the context's
/// ``VocabularyStore``.
public struct VocabularySettingsView: View {
    private static let explanation = """
        Add names and jargon so cleanup spells them your way. When speech-to-text writes one of a \
        term\u{2019}s spoken variants, it\u{2019}s replaced with the term.
        """

    @AppStorage(AppSettingsKey.vocabularyPromptLimit.rawValue)
    private var promptLimit = AppSettings.defaults.dictation.vocabularyPromptLimit

    @State private var model: VocabularyListModel
    @State private var selection: VocabularyEntry.ID?
    @State private var editing: VocabularyDraft?
    @State private var pendingDelete: VocabularyEntry?

    public init(context: DictationUIContext) {
        self.init(model: VocabularyListModel(store: context.vocabulary))
    }

    /// Shows `model`'s vocabulary; for previews and render checks.
    init(model: VocabularyListModel) {
        _model = State(initialValue: model)
    }

    public var body: some View {
        EditableListPane(
            explanation: Self.explanation + " " + VocabularyPromptLimitNote.text(storedLimit: promptLimit),
            status: model.status,
            retry: { await model.load() }
        ) {
            EditableListBox(actions: actions) {
                List(selection: $selection) {
                    ForEach(model.entries) { entry in
                        VocabularyRow(entry: entry)
                    }
                }
                .contextMenu(forSelectionType: VocabularyEntry.ID.self) { ids in
                    if let id = ids.first {
                        Button("Edit\u{2026}") { edit(id) }
                        Button("Delete\u{2026}") { confirmDelete(id) }
                    }
                } primaryAction: { ids in
                    if let id = ids.first { edit(id) }
                }
                .onDeleteCommand { confirmDelete(selection) }
                .overlay {
                    if model.entries.isEmpty {
                        ContentUnavailableView(
                            "No terms yet",
                            systemImage: "character.book.closed",
                            description: Text("Click + to add a name or a word.")
                        )
                    }
                }
            }
        }
        .sheet(item: $editing) { draft in
            VocabularyEditorSheet(model: model, draft: draft) { editing = nil }
        }
        .editableListDeleteConfirmation(
            $pendingDelete,
            title: { "Delete \u{201C}\($0.term)\u{201D} from your vocabulary?" },
            message: "Its spoken variants are deleted too. You can\u{2019}t undo this."
        ) { entry in
            Task {
                if await model.delete(id: entry.id), selection == entry.id { selection = nil }
            }
        }
        .task { await model.load() }
    }

    private var actions: EditableListActions {
        let canEdit = model.status.canEdit && model.entry(id: selection) != nil
        return EditableListActions(
            noun: "term",
            canAdd: model.status.canEdit,
            canEdit: canEdit,
            canDelete: canEdit,
            add: { editing = VocabularyDraft() },
            edit: { edit(selection) },
            delete: { confirmDelete(selection) }
        )
    }

    private func edit(_ id: VocabularyEntry.ID?) {
        guard model.status.canEdit, let entry = model.entry(id: id) else { return }
        editing = VocabularyDraft(editing: entry)
    }

    private func confirmDelete(_ id: VocabularyEntry.ID?) {
        guard model.status.canEdit, let entry = model.entry(id: id) else { return }
        pendingDelete = entry
    }
}

/// One term in the list, with its spoken variants underneath.
private struct VocabularyRow: View {
    let entry: VocabularyEntry

    var body: some View {
        let variants = entry.spokenVariants.isEmpty
            ? "No spoken variants"
            : entry.spokenVariants.joined(separator: ", ")
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.term)
                .fontWeight(.medium)
            Text(variants)
                .font(.callout)
                .foregroundStyle(entry.spokenVariants.isEmpty ? .tertiary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entry.term). \(variants)")
    }
}
