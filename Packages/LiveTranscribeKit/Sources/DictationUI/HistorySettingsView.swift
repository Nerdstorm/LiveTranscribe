import Shared
import SwiftUI

/// Settings › History: whether dictations are kept, for how long, and ways to see or clear them.
///
/// History stays on this Mac and is never synced (decision H2). Turning it off stops saving new
/// dictations; what is already kept stays until it is cleared or ages out.
struct HistorySettingsView: View {
    private static let defaults = AppSettings.defaults.dictation

    let context: DictationUIContext

    @AppStorage(AppSettingsKey.historyEnabled.rawValue) private var historyEnabled = defaults.historyEnabled
    @AppStorage(AppSettingsKey.historyRetentionDays.rawValue) private var retentionDays = defaults.historyRetentionDays

    @State private var model: HistorySettingsModel
    @State private var confirmingClear = false

    init(context: DictationUIContext) {
        self.context = context
        _model = State(initialValue: HistorySettingsModel(history: context.history))
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $historyEnabled) {
                    Text("Keep dictation history")
                    Text("History is stored only on this Mac and is never synced to iCloud or any other service.")
                }
                Picker("Keep dictations for", selection: $retentionDays) {
                    ForEach(HistorySettingsRetentionOption.options(including: retentionDays)) { option in
                        Text(option.title).tag(option.days)
                    }
                }
                if HistorySettingsRetentionOption.effectiveDays(retentionDays) > 0 {
                    Text("Older dictations are deleted automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                HStack {
                    Button("Show History…") { context.windows?.showHistory() }
                    Spacer()
                    Button("Clear History…", role: .destructive) { confirmingClear = true }
                        .disabled(model.isClearing)
                }
                if let error = model.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                } else if model.didClear {
                    Label("History cleared.", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Clear all dictation history?", isPresented: $confirmingClear) {
            Button("Clear History", role: .destructive) { clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every saved dictation is deleted from this Mac. This can't be undone.")
        }
    }

    private func clear() {
        Task {
            let cleared = await model.clear()
            SettingsRootAnnouncer.announce(cleared ? "History cleared" : (model.errorMessage ?? "Couldn't clear the history"))
        }
    }
}
