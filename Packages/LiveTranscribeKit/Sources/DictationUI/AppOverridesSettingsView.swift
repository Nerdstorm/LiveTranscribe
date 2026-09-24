import SwiftUI

/// Settings › Apps: how dictated text gets into particular apps. Shows the built-in settings
/// read-only and edits the user's own in `insertion-overrides.json` through the context's
/// ``AppOverridesStore``.
public struct AppOverridesSettingsView: View {
    private static let explanation = """
        Dictated text is typed in through Accessibility, and pasted when an app doesn\u{2019}t accept \
        that. Apps that ignore Accessibility, such as terminals and Electron apps, paste first. \
        Your setting for an app wins over the built-in one.
        """

    @State private var model: AppOverridesModel
    @State private var selection: AppOverrideRow.ID?
    @State private var editing: AppOverrideDraft?
    @State private var pendingDelete: AppOverrideRow?

    public init(context: DictationUIContext) {
        self.init(model: AppOverridesModel(store: context.overrides, catalog: SystemAppOverrideAppCatalog()))
    }

    /// Shows `model`'s settings; for previews and render checks.
    init(model: AppOverridesModel) {
        _model = State(initialValue: model)
    }

    public var body: some View {
        EditableListPane(explanation: Self.explanation, status: model.status, retry: { await model.load() }) {
            EditableListBox(actions: actions) {
                List(selection: $selection) {
                    Section("Your settings") {
                        if model.userRows.isEmpty {
                            Text("None yet. Click + to choose how an app gets its text.")
                                .foregroundStyle(.secondary)
                                .selectionDisabled()
                        }
                        ForEach(model.userRows) { row in
                            AppOverrideRowView(row: row)
                        }
                    }
                    Section("Built in") {
                        ForEach(model.builtInRows) { row in
                            AppOverrideRowView(row: row)
                        }
                    }
                }
                .contextMenu(forSelectionType: AppOverrideRow.ID.self) { ids in
                    if let row = model.row(id: ids.first) {
                        Button(row.source == .user ? "Edit\u{2026}" : "Change\u{2026}") { edit(row.id) }
                        if row.source == .user {
                            Button("Delete\u{2026}") { confirmDelete(row.id) }
                        }
                    }
                } primaryAction: { ids in
                    edit(ids.first)
                }
                .onDeleteCommand { confirmDelete(selection) }
            }
        }
        .sheet(item: $editing) { draft in
            AppOverrideEditorSheet(model: model, draft: draft) { editing = nil }
        }
        .editableListDeleteConfirmation(
            $pendingDelete,
            title: { "Delete your setting for \($0.app.name)?" },
            message: "The app goes back to the default, or to its built-in setting if it has one."
        ) { row in
            Task {
                if await model.delete(bundleIdentifier: row.bundleIdentifier), selection == row.id { selection = nil }
            }
        }
        .task { await model.load() }
    }

    private var actions: EditableListActions {
        let selected = model.status.canEdit ? model.row(id: selection) : nil
        return EditableListActions(
            noun: "setting",
            canAdd: model.status.canEdit,
            canEdit: selected != nil,
            canDelete: selected?.source == .user,
            add: { editing = model.newDraft() },
            edit: { edit(selection) },
            delete: { confirmDelete(selection) }
        )
    }

    private func edit(_ id: AppOverrideRow.ID?) {
        guard model.status.canEdit, let row = model.row(id: id) else { return }
        editing = model.draft(for: row)
    }

    private func confirmDelete(_ id: AppOverrideRow.ID?) {
        guard model.status.canEdit, let row = model.row(id: id), row.source == .user else { return }
        pendingDelete = row
    }
}

/// One app in the list with the method its setting picks; a built-in row the user has replaced
/// says so.
private struct AppOverrideRowView: View {
    let row: AppOverrideRow

    var body: some View {
        HStack(spacing: 8) {
            AppOverrideAppLabel(app: row.app)
            Spacer(minLength: 8)
            if row.isReplacedByUser {
                Text("Your setting applies")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(row.method.displayName)
                .foregroundStyle(row.isReplacedByUser ? .tertiary : .secondary)
                .strikethrough(row.isReplacedByUser)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let method = "\(row.app.name), \(row.method.displayName)"
        return row.isReplacedByUser ? "\(method), replaced by your setting" : method
    }
}
