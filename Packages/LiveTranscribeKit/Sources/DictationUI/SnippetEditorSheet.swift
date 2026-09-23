import SwiftUI

/// The sheet that adds or edits one snippet: its trigger phrase and the text it inserts.
struct SnippetEditorSheet: View {
    private let model: SnippetListModel
    private let close: () -> Void
    @State private var draft: SnippetDraft
    @FocusState private var triggerIsFocused: Bool

    /// - Parameters:
    ///   - model: Checks and saves the draft.
    ///   - draft: The snippet to edit, or an empty draft for a new one.
    ///   - close: Dismisses the sheet.
    init(model: SnippetListModel, draft: SnippetDraft, close: @escaping () -> Void) {
        self.model = model
        self.close = close
        _draft = State(initialValue: draft)
    }

    var body: some View {
        EditableListEditorSheet(
            title: draft.isNew ? "New snippet" : "Edit snippet",
            saveTitle: draft.isNew ? "Add" : "Save",
            validation: model.validation(of: draft),
            errorMessage: model.status.errorMessage,
            isSaving: model.status.isWorking,
            savesWithCommandReturn: true,
            cancel: close,
            save: save
        ) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Trigger phrase")
                TextField("Trigger phrase", text: $draft.trigger, prompt: Text("my calendar link"))
                    .labelsHidden()
                    .focused($triggerIsFocused)
                    .onSubmit(save)
                EditableListFieldNote("What you say while dictating.")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Text to insert")
                EditableListPlainTextEditor(text: $draft.expansion, accessibilityLabel: "Text to insert")
                    .frame(minHeight: 110, idealHeight: 140)
                EditableListFieldNote("Inserted exactly as written, including line breaks. Cleanup never changes it.")
            }
        }
        .onAppear {
            model.status.dismissError()
            triggerIsFocused = true
        }
    }

    private func save() {
        Task {
            if await model.save(draft) { close() }
        }
    }
}
