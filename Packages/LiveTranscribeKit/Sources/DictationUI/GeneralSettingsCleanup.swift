import Shared
import SwiftUI

/// The notes under the cleanup level picker: what applies at every level, what the Advanced
/// settings stop from applying, and when a change there takes effect.
///
/// The per-level lines come from ``CleanupLevel/summary``. These notes cover what those lines
/// leave out: dictation applies snippets, vocabulary and spoken commands at every level (they run
/// before the language model; None's line says so too, and the live transcript applies none of
/// them), and
/// self-corrections are resolved only with the fine-tuned adapter
/// (`PromptBuilder.levelRules(for:adapted:)`), which Advanced can turn off.
///
/// The cleanup model and its adapter are loaded at launch, so the notes describe the switches
/// in effect since then (``DictationUIContext/settingsAtLaunch``) and say when Advanced holds a
/// change that waits for a restart.
enum GeneralSettingsCleanupNotes {
    /// The two Advanced switches the notes depend on.
    struct ModelSwitches: Equatable {
        var cleanupEnabled: Bool
        var adapterEnabled: Bool

        init(cleanupEnabled: Bool, adapterEnabled: Bool) {
            self.cleanupEnabled = cleanupEnabled
            self.adapterEnabled = adapterEnabled
        }

        init(settings: AppSettings) {
            self.init(cleanupEnabled: settings.cleanupEnabled, adapterEnabled: settings.cleanupAdapterEnabled)
        }
    }

    /// - Parameters:
    ///   - inEffect: The switches Live Transcribe started with, which apply until it restarts.
    ///   - stored: The switches as Advanced shows them now.
    static func text(level: CleanupLevel, inEffect: ModelSwitches, stored: ModelSwitches) -> String {
        var notes = [
            "Applies to dictation and the live transcript, on this Mac.",
            "Dictation applies your snippets, vocabulary and spoken commands at every level.",
        ]
        if let model = modelNote(inEffect: inEffect, stored: stored) {
            notes.append(model)
        } else if level.resolvesSelfCorrections, let adapter = adapterNote(inEffect: inEffect, stored: stored) {
            notes.append(adapter)
        }
        return notes.joined(separator: " ")
    }

    /// What the levels do without the cleanup model. Filler removal and layout need no model
    /// (`CleanupExecutor.deterministicCleanup`, `Layout`); the live transcript runs no cleanup at
    /// all without it.
    static let withoutModel = "nothing is reworded: dictation still removes filler words and lays out spoken lists and letters at Medium and High, and the live transcript shows what was heard."

    /// The cleanup model when it is off or is about to change; `nil` while it is on and stays on.
    private static func modelNote(inEffect: ModelSwitches, stored: ModelSwitches) -> String? {
        switch (inEffect.cleanupEnabled, stored.cleanupEnabled) {
        case (true, true): nil
        case (true, false): "The cleanup model turns off the next time Live Transcribe starts."
        case (false, false): "The cleanup model is off in Advanced, so \(withoutModel)"
        case (false, true): "The cleanup model is off until Live Transcribe restarts, so \(withoutModel)"
        }
    }

    /// The self-correction adapter, while the model stays on, when it is off or is about to
    /// change; `nil` while it is on and stays on.
    private static func adapterNote(inEffect: ModelSwitches, stored: ModelSwitches) -> String? {
        switch (inEffect.adapterEnabled, stored.adapterEnabled) {
        case (true, true): nil
        case (true, false): "Resolve spoken self-corrections turns off the next time Live Transcribe starts."
        case (false, false): "Self-corrections are kept as spoken, because Resolve spoken self-corrections is off in Advanced."
        case (false, true): "Self-corrections are kept as spoken until Live Transcribe restarts and Resolve spoken self-corrections turns on."
        }
    }
}

/// Settings › General › Cleanup: the level, as a radio group with a line on what each does.
struct GeneralSettingsCleanupSection: View {
    /// The Advanced switches Live Transcribe started with; see
    /// ``DictationUIContext/settingsAtLaunch``.
    let inEffect: GeneralSettingsCleanupNotes.ModelSwitches

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
                inEffect: inEffect,
                stored: .init(cleanupEnabled: cleanupEnabled, adapterEnabled: adapterEnabled)
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
