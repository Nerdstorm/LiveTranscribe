import Insertion
import SwiftUI

/// The sheet that adds a per-app setting (choosing the app from those running, or any app on
/// disk) or changes an existing setting's method.
struct AppOverrideEditorSheet: View {
    /// Tall enough for about six running apps.
    private static var runningListHeight: CGFloat { 170 }

    private let model: AppOverridesModel
    private let close: () -> Void
    /// The draft started without an app, so the sheet lists apps to choose from; otherwise the
    /// app is fixed and only its method can change.
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
            VStack(alignment: .leading, spacing: 6) {
                Picker("Insert text with", selection: $draft.method) {
                    ForEach(InsertionMethod.allCases, id: \.self) { method in
                        Text(method.displayName).tag(method)
                    }
                }
                .pickerStyle(.radioGroup)
                EditableListFieldNote(AppOverrideMethodText.summary(draft.method))
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

    /// Makes `app` the draft's app, starting with the method it doesn't use now.
    private func use(_ app: AppOverrideApp) {
        choiceError = nil
        guard draft.app != app else { return }
        draft.app = app
        draft.method = model.suggestedMethod(for: app.bundleIdentifier)
    }

    private func save() {
        Task {
            if await model.save(draft) { close() }
        }
    }
}
