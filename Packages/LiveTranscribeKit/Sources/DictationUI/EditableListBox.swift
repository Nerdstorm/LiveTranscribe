import SwiftUI

/// What the buttons under an editable list can do right now.
struct EditableListActions {
    /// What one item is called in the buttons' labels ("snippet", "term", "app").
    let noun: String
    let canAdd: Bool
    let canEdit: Bool
    let canDelete: Bool
    let add: () -> Void
    let edit: () -> Void
    let delete: () -> Void
}

/// A bordered list with the standard macOS add, remove and edit buttons attached underneath.
struct EditableListBox<ListContent: View>: View {
    /// Tall enough for a handful of rows; the Settings window gives it more room when it has it.
    private static var minimumHeight: CGFloat { 180 }

    private let actions: EditableListActions
    private let list: ListContent

    init(actions: EditableListActions, @ViewBuilder list: () -> ListContent) {
        self.actions = actions
        self.list = list()
    }

    var body: some View {
        VStack(spacing: 0) {
            list
                .frame(minHeight: Self.minimumHeight)
            Divider()
            EditableListButtonBar(actions: actions)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

/// The + and − buttons, and Edit, under an ``EditableListBox``.
struct EditableListButtonBar: View {
    let actions: EditableListActions

    var body: some View {
        HStack(spacing: 2) {
            Button(action: actions.add) {
                Image(systemName: "plus").frame(width: 22, height: 18)
            }
            .disabled(!actions.canAdd)
            .help("Add \(actions.noun)")
            .accessibilityLabel("Add \(actions.noun)")

            Button(action: actions.delete) {
                Image(systemName: "minus").frame(width: 22, height: 18)
            }
            .disabled(!actions.canDelete)
            .help("Delete \(actions.noun)")
            .accessibilityLabel("Delete \(actions.noun)")

            Spacer()

            Button("Edit\u{2026}", action: actions.edit)
                .disabled(!actions.canEdit)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

extension View {
    /// Asks before deleting `item`, whenever it is set; clears it when the user answers.
    ///
    /// - Parameters:
    ///   - item: The item waiting for confirmation; `nil` shows nothing.
    ///   - title: The question, naming the item ("Delete “my link”?").
    ///   - message: What deleting it means.
    ///   - delete: Runs when the user confirms.
    func editableListDeleteConfirmation<Item>(
        _ item: Binding<Item?>,
        title: @escaping (Item) -> String,
        message: String,
        delete: @escaping (Item) -> Void
    ) -> some View {
        modifier(EditableListDeleteConfirmation(item: item, title: title, message: message, delete: delete))
    }
}

/// See ``SwiftUI/View/editableListDeleteConfirmation(_:title:message:delete:)``.
private struct EditableListDeleteConfirmation<Item>: ViewModifier {
    @Binding var item: Item?
    let title: (Item) -> String
    let message: String
    let delete: (Item) -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(
            item.map(title) ?? "",
            isPresented: Binding(get: { item != nil }, set: { if !$0 { item = nil } }),
            titleVisibility: .visible,
            presenting: item
        ) { pending in
            Button("Delete", role: .destructive) { delete(pending) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(message)
        }
    }
}
