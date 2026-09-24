import SwiftUI
import Updates

/// Settings › General › Updates: whether the app checks for new releases by itself, and a way to
/// check now. Only a release shows it (see ``SoftwareUpdating``).
///
/// The choice is Sparkle's own setting, which its second-launch prompt also sets, so this reads
/// and writes it through ``SoftwareUpdating`` rather than `@AppStorage`.
struct GeneralSettingsUpdatesSection: View {
    let updates: any SoftwareUpdating

    var body: some View {
        Section("Updates") {
            Toggle(isOn: automaticChecks) {
                Text("Check for updates automatically")
                Text("About once a day, from GitHub. Only the app's version is sent, never your dictation.")
            }
            LabeledContent {
                Button("Check Now") { updates.checkForUpdates() }
                    .disabled(!updates.canCheckForUpdates)
            } label: {
                Text(GeneralSettingsUpdatesText.lastChecked(updates.lastUpdateCheckDate))
            }
        }
    }

    private var automaticChecks: Binding<Bool> {
        Binding(
            get: { updates.automaticallyChecksForUpdates },
            set: { updates.automaticallyChecksForUpdates = $0 }
        )
    }
}

/// What the Updates section says.
enum GeneralSettingsUpdatesText {
    /// When the app last checked, such as "Last checked 24 Sep 2026 at 9:41 pm".
    static func lastChecked(_ date: Date?) -> String {
        guard let date else { return "Not checked yet" }
        return "Last checked \(date.formatted(date: .abbreviated, time: .shortened))"
    }
}
