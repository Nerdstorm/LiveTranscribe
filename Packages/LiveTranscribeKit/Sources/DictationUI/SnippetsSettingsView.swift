import Snippets
import SwiftUI

/// Settings › Snippets: phrases the user says while dictating, each replaced by text inserted
/// exactly as written. Edits `snippets.json` through the context's ``SnippetStore``.
public struct SnippetsSettingsView: View {
    private static let explanation = """
        Say a snippet\u{2019}s trigger phrase while dictating to insert its text exactly as \
        written. Cleanup never changes a snippet\u{2019}s text.
        """

    @State private var model: SnippetListModel
    @State private var selection: Snippet.ID?
    @State private var editing: SnippetDraft?
    @State private var pendingDelete: Snippet?

    public init(context: DictationUIContext) {
        self.init(model: SnippetListModel(store: context.snippets))
    }

    /// Shows `model`'s snippets; for previews and render checks.
    init(model: SnippetListModel) {
        _model = State(initialValue: model)
    }

    public var body: some View {
        EditableListPane(explanation: Self.explanation, status: model.status, retry: { await model.load() }) {
            EditableListBox(actions: actions) {
                List(selection: $selection) {
                    ForEach(model.snippets) { snippet in
                        SnippetRow(snippet: snippet)
                    }
                }
                .contextMenu(forSelectionType: Snippet.ID.self) { ids in
                    if let id = ids.first {
                        Button("Edit\u{2026}") { edit(id) }
                        Button("Delete\u{2026}") { confirmDelete(id) }
                    }
                } primaryAction: { ids in
                    if let id = ids.first { edit(id) }
                }
                .onDeleteCommand { confirmDelete(selection) }
                .overlay {
                    if model.snippets.isEmpty {
                        ContentUnavailableView(
                            "No snippets yet",
                            systemImage: "text.badge.plus",
                            description: Text("Click + to add a phrase and the text it inserts.")
                        )
                    }
                }
            }
        }
        .sheet(item: $editing) { draft in
            SnippetEditorSheet(model: model, draft: draft) { editing = nil }
        }
        .editableListDeleteConfirmation(
            $pendingDelete,
            title: { "Delete the snippet \u{201C}\($0.trigger)\u{201D}?" },
            message: "Its text is deleted too. You can\u{2019}t undo this."
        ) { snippet in
            Task {
                if await model.delete(id: snippet.id), selection == snippet.id { selection = nil }
            }
        }
        .task { await model.load() }
    }

    private var actions: EditableListActions {
        let canEdit = model.status.canEdit && model.snippet(id: selection) != nil
        return EditableListActions(
            noun: "snippet",
            canAdd: model.status.canEdit,
            canEdit: canEdit,
            canDelete: canEdit,
            add: { editing = SnippetDraft() },
            edit: { edit(selection) },
            delete: { confirmDelete(selection) }
        )
    }

    private func edit(_ id: Snippet.ID?) {
        guard model.status.canEdit, let snippet = model.snippet(id: id) else { return }
        editing = SnippetDraft(editing: snippet)
    }

    private func confirmDelete(_ id: Snippet.ID?) {
        guard model.status.canEdit, let snippet = model.snippet(id: id) else { return }
        pendingDelete = snippet
    }
}

/// One snippet in the list: its trigger, and the start of the text it inserts.
private struct SnippetRow: View {
    let snippet: Snippet

    var body: some View {
        let preview = SnippetExpansionPreview.text(for: snippet.expansion)
        HStack(spacing: 8) {
            Text(snippet.trigger)
                .fontWeight(.medium)
                .lineLimit(1)
                .layoutPriority(1)
            Image(systemName: "arrow.right")
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(preview)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(snippet.trigger), inserts \(preview)")
    }
}
