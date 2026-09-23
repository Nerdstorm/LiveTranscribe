import AppKit
import Dictation
import Permissions
import Shared
import SwiftUI
import TranscriptUI

/// The menu bar menu: dictation status and controls, stopping the live transcript, the cleanup
/// level, the microphone, and the app's windows.
///
/// Made for `MenuBarExtra { MenuBarContent(context:) } label: { MenuBarLabel(context:) }` with
/// `.menuBarExtraStyle(.menu)`, so it uses only views a menu can show. What it says and allows
/// comes from ``MenuBarStatus`` and, for the microphone, ``MicrophonePickerList``; settings go
/// through `UserDefaults`, which the app applies to the controller.
public struct MenuBarContent: View {
    private static let d = AppSettings.defaults

    @AppStorage(AppSettingsKey.cleanupLevel.rawValue) private var cleanupLevel = d.cleanupLevel
    @AppStorage(AppSettingsKey.showVirtualInputDevices.rawValue)
    private var showOtherDevices = d.dictation.showVirtualInputDevices
    @AppStorage(AppSettingsKey.dictationHotkey.rawValue) private var dictationHotkey = d.dictation.hotkey
    @AppStorage(AppSettingsKey.undoHotkey.rawValue) private var undoHotkey = d.dictation.undoHotkey
    /// Bumped whenever a menu opens. Permissions are not observable, so reading this makes the
    /// menu check them again each time it is shown, and a change made in System Settings shows.
    @State private var menuOpenings = 0

    let context: DictationUIContext

    public init(context: DictationUIContext) {
        self.context = context
    }

    public var body: some View {
        let controller = context.controller
        let transcript = context.transcript
        let _ = menuOpenings
        let microphone = context.microphonePermission.status()
        let status = MenuBarStatus(
            phase: controller.phase,
            hotkey: controller.hotkeyState,
            session: transcript.phase,
            modelProgress: transcript.modelProgress,
            microphone: microphone,
            hasLastDictation: controller.lastText != nil
        )
        let permissions = PermissionSnapshot(microphone: microphone, accessibility: context.accessibility.isGranted())

        Text(status.indicator.statusText)
            .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
                menuOpenings &+= 1
            }
        if status.canStopLiveTranscript {
            // Right under the status line, which then usually reads "Stop the live transcript to
            // dictate", so it stops from any app without finding the transcript window.
            Button("Stop Live Transcript") { transcript.stopListening() }
        }
        Button(status.toggleTitle) { controller.toggleDictation() }
            .disabled(!status.canToggleDictation)
        if status.canCancel {
            Button("Cancel Dictation") { controller.cancel() }
        }
        Button(MenuBarStatus.undoTitle(undoHotkey: undoHotkey, dictationHotkey: dictationHotkey, hotkey: controller.hotkeyState)) {
            controller.undoLastEdit()
        }
        .disabled(!status.canUndo)
        Button("Copy Last Dictation", action: copyLastDictation)
            .disabled(!status.canCopyLastDictation)

        Divider()

        Picker("Cleanup", selection: $cleanupLevel) {
            ForEach(CleanupLevel.allCases) { level in
                Text(level.displayName)
                    .help(level.summary)
                    .tag(level)
            }
        }
        if transcript.supportsInputSelection {
            MenuMicrophoneSubmenu(transcript: transcript, showOtherDevices: $showOtherDevices)
        }

        Divider()

        Button("Live Transcript…") { showWindow("the live transcript") { $0.showTranscript() } }
        Button("Dictation History…") { showWindow("the dictation history") { $0.showHistory() } }
        Button("Settings…") { showWindow("Settings") { $0.showSettings(tab: nil) } }
            .keyboardShortcut(",")
        if !permissions.allGranted {
            Button("Set Up Dictation…") { showWindow("setup") { $0.showOnboarding() } }
        }

        Divider()

        Button("Quit Live Transcribe") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// Copies the last dictation, for when it landed somewhere unexpected.
    private func copyLastDictation() {
        guard let text = context.controller.lastText else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if !pasteboard.setString(text, forType: .string) {
            // The menu has closed, so a beep is the only feedback left.
            Log.ui.error("Couldn't copy the last dictation to the clipboard")
            NSSound.beep()
        }
    }

    /// Runs a window action, or logs that the app never connected the windows.
    private func showWindow(_ name: String, _ action: (any DictationWindowActions) -> Void) {
        guard let windows = context.windows else {
            Log.ui.error("Can't show \(name, privacy: .public): no window actions are connected")
            NSSound.beep()
            return
        }
        action(windows)
    }
}
