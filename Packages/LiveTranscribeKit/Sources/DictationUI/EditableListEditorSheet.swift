import SwiftUI

/// The chrome every add and edit sheet shares: a title, the fields, the validation message under
/// them, and Cancel and Save. Save stays off until the fields are valid and while a save runs.
struct EditableListEditorSheet<Fields: View>: View {
    /// Wide enough for a URL or an address on one line.
    private static var width: CGFloat { 460 }

    private let title: String
    private let saveTitle: String
    private let validation: EditableListValidation
    private let errorMessage: String?
    private let isSaving: Bool
    private let savesWithCommandReturn: Bool
    private let cancel: () -> Void
    private let save: () -> Void
    private let fields: Fields

    /// - Parameters:
    ///   - title: The sheet's heading ("New snippet").
    ///   - saveTitle: The confirming button ("Add" for a new item, "Save" for an edit).
    ///   - validation: Whether the fields can be saved, shown under them.
    ///   - errorMessage: Why the last save failed, if it did.
    ///   - isSaving: A save is running.
    ///   - savesWithCommandReturn: Save with ⌘Return instead of Return, for sheets with a
    ///     multi-line field where Return types a line break.
    ///   - cancel: Closes the sheet without saving.
    ///   - save: Saves; the caller closes the sheet when it succeeds.
    init(
        title: String,
        saveTitle: String,
        validation: EditableListValidation,
        errorMessage: String?,
        isSaving: Bool,
        savesWithCommandReturn: Bool,
        cancel: @escaping () -> Void,
        save: @escaping () -> Void,
        @ViewBuilder fields: () -> Fields
    ) {
        self.title = title
        self.saveTitle = saveTitle
        self.validation = validation
        self.errorMessage = errorMessage
        self.isSaving = isSaving
        self.savesWithCommandReturn = savesWithCommandReturn
        self.cancel = cancel
        self.save = save
        self.fields = fields()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            fields

            EditableListValidationMessage(validation: validation, errorMessage: errorMessage)

            HStack {
                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Saving")
                }
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button(saveTitle, action: save)
                    .keyboardShortcut(savesWithCommandReturn ? KeyboardShortcut(.return, modifiers: .command) : .defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!validation.canSave || isSaving)
                    .help(savesWithCommandReturn ? "\(saveTitle) (\u{2318}\u{21A9})" : saveTitle)
            }
        }
        .padding(20)
        .frame(width: Self.width)
    }
}

/// The line under an editor's fields: what is missing (a quiet hint), what is wrong, and why the
/// last save failed.
struct EditableListValidationMessage: View {
    let validation: EditableListValidation
    let errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch validation {
            case .valid:
                EmptyView()
            case .incomplete(let message):
                Text(message)
                    .foregroundStyle(.secondary)
            case .invalid(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
            }
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}

/// A short explanation under a field in an editor sheet.
struct EditableListFieldNote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
