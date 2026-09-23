import Shared
import SwiftUI

/// The notes under the cleanup level picker: what applies at every level, and what the
/// Advanced settings stop from applying.
///
/// The per-level lines come from ``CleanupLevel/summary``. These notes cover what that line
/// cannot know: snippets and vocabulary apply even at None (they run before the language model),
/// and self-corrections are resolved only with the fine-tuned adapter
/// (`PromptBuilder.levelRules(for:adapted:)`), which Advanced can turn off.
enum GeneralSettingsCleanupNotes {
    static func text(level: CleanupLevel, cleanupEnabled: Bool, adapterEnabled: Bool) -> String {
        var notes = ["Applies to dictation and the live transcript, on this Mac. Snippets and vocabulary apply at every level."]
        if !cleanupEnabled {
            notes.append("The cleanup model is off in Advanced, so every level works like None until it's back on.")
        } else if !adapterEnabled, level.resolvesSelfCorrections {
            notes.append("Self-corrections are kept as spoken, because Resolve spoken self-corrections is off in Advanced.")
        }
        return notes.joined(separator: " ")
    }
}

/// Settings › General › Cleanup: the level, as a radio group with a line on what each does.
struct GeneralSettingsCleanupSection: View {
    @AppStorage(AppSettingsKey.cleanupLevel.rawValue) private var cleanupLevel = AppSettings.defaults.cleanupLevel
    @AppStorage(AppSettingsKey.cleanupEnabled.rawValue) private var cleanupEnabled = AppSettings.defaults.cleanupEnabled
    @AppStorage(AppSettingsKey.cleanupAdapterEnabled.rawValue)
    private var adapterEnabled = AppSettings.defaults.cleanupAdapterEnabled

    var body: some View {
        Section {
            Picker("Cleanup level", selection: $cleanupLevel) {
                ForEach(CleanupLevel.allCases) { level in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(level.displayName)
                        Text(level.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(level)
                    .accessibilityElement(children: .combine)
                }
            }
            .pickerStyle(.radioGroup)
            // The section header names it; VoiceOver still reads the label.
            .labelsHidden()
        } header: {
            Text("Cleanup")
        } footer: {
            Text(GeneralSettingsCleanupNotes.text(
                level: cleanupLevel,
                cleanupEnabled: cleanupEnabled,
                adapterEnabled: adapterEnabled
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
