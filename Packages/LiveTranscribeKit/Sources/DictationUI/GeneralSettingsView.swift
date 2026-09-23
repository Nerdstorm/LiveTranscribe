import AppKit
import Dictation
import Hotkey
import Shared
import SwiftUI

/// Settings › General: turning dictation on, its shortcuts, the cleanup level, the microphone
/// and the timing group.
///
/// Every value is read and written through `@AppStorage`; the app watches UserDefaults and
/// applies changes to the dictation controller, so they take effect on the next dictation.
struct GeneralSettingsView: View {
    private static let defaults = AppSettings.defaults.dictation

    let context: DictationUIContext
    /// Switches the Settings window to another tab, for links such as *Open Permissions*.
    let showTab: (SettingsTab) -> Void

    @AppStorage(AppSettingsKey.dictationEnabled.rawValue) private var dictationEnabled = defaults.enabled
    @AppStorage(AppSettingsKey.dictationHotkey.rawValue) private var dictationHotkey = defaults.hotkey
    @AppStorage(AppSettingsKey.undoHotkey.rawValue) private var undoHotkey = defaults.undoHotkey
    @AppStorage(AppSettingsKey.handsFreeEnabled.rawValue) private var handsFreeEnabled = defaults.handsFreeEnabled

    @State private var fnKey = GeneralSettingsFnKeyModel()
    /// The shortcut recorder that is recording, if any; see ``HotkeyRecorderView``.
    @State private var activeRecorder: String?

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $dictationEnabled) {
                    Text("Enable dictation")
                    Text("Hold the shortcut in any app, speak, and let go to insert the text.")
                }
            }
            shortcutsSection
            GeneralSettingsCleanupSection()
            GeneralSettingsMicrophoneSection(transcript: context.transcript)
            Section {
                GeneralSettingsTimingSection()
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            fnKey.refresh()
        }
        .onAppear { fnKey.refresh() }
    }

    // MARK: - Sections

    private var shortcutsSection: some View {
        Section("Shortcuts") {
            LabeledContent("Dictation shortcut") {
                HotkeyRecorderView(
                    title: "Dictation shortcut",
                    storage: $dictationHotkey,
                    defaultBinding: .defaultDictation,
                    configuration: .init(
                        allowsModifierOnly: true,
                        otherShortcut: HotkeyRecorderModel.binding(storage: undoHotkey, fallback: .defaultUndo),
                        otherShortcutPurpose: "Undo AI edit"
                    ),
                    activeRecorder: $activeRecorder,
                    suspendHotkeys: context.controller.suspendHotkeys
                )
            }
            if fnKey.showsWarning(forStoredHotkey: dictationHotkey) {
                GeneralSettingsFnKeyWarning(model: fnKey)
            }
            shortcutStatus
            Toggle(isOn: $handsFreeEnabled) {
                Text("Double-tap the shortcut for hands-free")
                Text("Keep talking without holding the key. Press it again to finish.")
            }
            LabeledContent("Undo AI edit") {
                HotkeyRecorderView(
                    title: "Undo AI edit shortcut",
                    storage: $undoHotkey,
                    defaultBinding: .defaultUndo,
                    configuration: .init(
                        allowsModifierOnly: false,
                        otherShortcut: HotkeyRecorderModel.binding(storage: dictationHotkey, fallback: .defaultDictation),
                        otherShortcutPurpose: "dictation"
                    ),
                    activeRecorder: $activeRecorder,
                    suspendHotkeys: context.controller.suspendHotkeys
                )
            }
            .help("Puts back what you said, without cleanup, shortly after a dictation.")
        }
    }

    /// A problem with the dictation shortcut, if there is one, with a way to fix it.
    @ViewBuilder private var shortcutStatus: some View {
        let status = PermissionsSettingsShortcutStatus(context.controller.hotkeyState)
        if status.isProblem {
            HStack(alignment: .firstTextBaseline) {
                Label(status.message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
                Spacer()
                if status.needsAccessibility {
                    Button("Open Permissions") { showTab(.permissions) }
                }
            }
            .accessibilityElement(children: .combine)
        }
    }
}
