import SwiftUI

/// The sheet that adds or edits one vocabulary term and the ways speech-to-text mishears it.
struct VocabularyEditorSheet: View {
    private let model: VocabularyListModel
    private let close: () -> Void
    @State private var draft: VocabularyDraft
    @FocusState private var termIsFocused: Bool

    /// - Parameters:
    ///   - model: Checks and saves the draft.
    ///   - draft: The entry to edit, or an empty draft for a new one.
    ///   - close: Dismisses the sheet.
    init(model: VocabularyListModel, draft: VocabularyDraft, close: @escaping () -> Void) {
        self.model = model
        self.close = close
        _draft = State(initialValue: draft)
    }

    var body: some View {
        EditableListEditorSheet(
            title: draft.isNew ? "New term" : "Edit term",
            saveTitle: draft.isNew ? "Add" : "Save",
            validation: model.validation(of: draft),
            errorMessage: model.status.errorMessage,
            isSaving: model.status.isWorking,
            savesWithCommandReturn: true,
            cancel: close,
            save: save
        ) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Term")
                TextField("Term", text: $draft.term, prompt: Text("Nerdstorm"))
                    .labelsHidden()
                    .focused($termIsFocused)
                    .onSubmit(save)
                EditableListFieldNote("Spelled the way you want it written.")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Spoken variants")
                EditableListPlainTextEditor(text: $draft.variantsText, accessibilityLabel: "Spoken variants, one per line")
                    .frame(minHeight: 90, idealHeight: 110)
                EditableListFieldNote(
                    "One per line. How speech-to-text writes the term when it mishears it, like \u{201C}nerd storm\u{201D}. Optional."
                )
            }
        }
        .onAppear {
            model.status.dismissError()
            termIsFocused = true
        }
    }

    private func save() {
        Task {
            if await model.save(draft) { close() }
        }
    }
}
