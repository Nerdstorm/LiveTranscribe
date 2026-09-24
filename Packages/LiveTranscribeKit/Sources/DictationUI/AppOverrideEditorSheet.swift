import Insertion
import SwiftUI

/// The sheet that adds a per-app setting (choosing the app from those running, or any app on
/// disk) or changes an existing one: how the app gets its text, and whether it takes line breaks.
struct AppOverrideEditorSheet: View {
    /// Tall enough for about six running apps.
    private static var runningListHeight: CGFloat { 170 }

    private let model: AppOverridesModel
    private let close: () -> Void
    /// The draft started without an app, so the sheet lists apps to choose from; otherwise the
    /// app is fixed and only its settings can change.
    private let choosesApp: Bool
    private let title: String
    @State private var draft: AppOverrideDraft
    @State private var runningSelection: AppOverrideApp.ID?
    /// Why the app chosen in the Open panel can't be used.
    @State private var choiceError: String?

    /// - Parameters:
    ///   - model: Lists running apps, and checks and saves the draft.
    ///   - draft: The setting to edit, or a new draft (with or without an app chosen).
    ///   - close: Dismisses the sheet.
    init(model: AppOverridesModel, draft: AppOverrideDraft, close: @escaping () -> Void) {
        self.model = model
        self.close = close
        choosesApp = draft.app == nil
        title = draft.app.map { "Setting for \($0.name)" } ?? "Add an app"
        _draft = State(initialValue: draft)
    }

    var body: some View {
        EditableListEditorSheet(
            title: title,
            saveTitle: draft.isNew ? "Add" : "Save",
            validation: model.validation(of: draft),
            errorMessage: choiceError ?? model.status.errorMessage,
            isSaving: model.status.isWorking,
            savesWithCommandReturn: false,
            cancel: close,
            save: save
        ) {
            if choosesApp {
                appChooser
            } else if let app = draft.app {
                AppOverrideAppLabel(app: app)
            }
            // One grid, so both choices line up beside their labels.
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 16) {
                GridRow {
                    Text("Insert text with")
                    VStack(alignment: .leading, spacing: 6) {
                        choice(InsertionMethod.allCases, selection: $draft.method, label: "Insert text with", name: \.displayName)
                        EditableListFieldNote(AppOverrideMethodText.summary(draft.method))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                GridRow {
                    Text("Line breaks")
                    VStack(alignment: .leading, spacing: 6) {
                        choice(LineMode.allCases, selection: $draft.lineMode, label: "Line breaks", name: \.displayName)
                        EditableListFieldNote(AppOverrideLineText.summary(draft.lineMode))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .onAppear {
            model.status.dismissError()
            // Only a sheet that chooses its app lists running ones. Selecting the draft's app in
            // that list would swap it for the running copy, which can spell the identifier
            // differently from the setting being edited.
            if choosesApp { model.refreshRunningApps() }
        }
        .onChange(of: runningSelection) { _, id in
            guard let id, let app = model.runningApps.first(where: { $0.id == id }) else { return }
            use(app)
        }
    }

    /// Radio buttons for `options`; the grid shows the label, so the picker only names itself to
    /// VoiceOver.
    private func choice<Option: Hashable>(
        _ options: [Option],
        selection: Binding<Option>,
        label: String,
        name: KeyPath<Option, String>
    ) -> some View {
        Picker(label, selection: selection) {
            ForEach(options, id: \.self) { option in
                Text(option[keyPath: name]).tag(option)
            }
        }
        .pickerStyle(.radioGroup)
        .labelsHidden()
    }

    /// The running apps to pick from, a button for any other app, and the app chosen that way.
    @ViewBuilder private var appChooser: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Running apps")
            List(model.runningApps, selection: $runningSelection) { app in
                AppOverrideAppLabel(app: app)
            }
            .listStyle(.bordered(alternatesRowBackgrounds: false))
            .frame(height: Self.runningListHeight)
            .accessibilityLabel("Running apps")
            .overlay {
                if model.runningApps.isEmpty {
                    Text("Every running app already has a setting.")
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Choose Another App\u{2026}", action: chooseApp)
                if let app = draft.app, runningSelection != app.id {
                    AppOverrideAppLabel(app: app)
                }
            }
        }
    }

    private func chooseApp() {
        guard let url = AppOverrideAppChooser.chooseApp() else { return }
        guard let app = model.chosenApp(at: url) else {
            choiceError = AppOverridesModel.unidentifiedAppMessage
            return
        }
        runningSelection = model.runningApps.contains { $0.id == app.id } ? app.id : nil
        use(app)
    }

    /// Makes `app` the draft's app, starting from the settings that apply to it now.
    private func use(_ app: AppOverrideApp) {
        choiceError = nil
        guard draft.app != app else { return }
        draft.app = app
        (draft.method, draft.lineMode) = model.currentSettings(for: app.bundleIdentifier)
    }

    private func save() {
        Task {
            if await model.save(draft) { close() }
        }
    }
}
