import AppKit
import DictationUI
import Shared
import SwiftUI
import TranscriptUI

/// Opens the app's windows from the menu bar.
///
/// The app lives in the menu bar (LSUIElement), so it has no Dock icon and cannot take focus on
/// its own. While any window is open it becomes a regular app, with a Dock icon and a main menu,
/// so the window comes forward and can be switched to; when the last one closes it returns to
/// the menu bar.
///
/// Closing the transcript window stops the live transcript: the app keeps running in the menu
/// bar, and a transcript left listening with no window would keep the microphone open and block
/// dictation.
@MainActor
final class WindowPresenter: NSObject, DictationWindowActions, NSWindowDelegate {
    private enum Kind: String {
        case transcript, history, settings, onboarding
    }

    private let context: DictationUIContext
    private var windows: [Kind: NSWindow] = [:]
    /// The Settings window's tab, kept for the app's lifetime so Settings reopens where it was left.
    private let settingsNavigation = SettingsNavigation()

    init(context: DictationUIContext) {
        self.context = context
    }

    func showTranscript() {
        present(.transcript, title: "Live Transcribe", size: NSSize(width: 440, height: 520), resizable: true) {
            TranscriptWindow(model: context.transcript)
        }
    }

    func showHistory() {
        present(.history, title: "Dictation History", size: NSSize(width: 720, height: 520), resizable: true) {
            HistoryWindowView(context: context)
        }
    }

    /// Only the tab changes on a window that is already open. Its view is never replaced, so an
    /// editor sheet and its unsaved draft survive.
    func showSettings(tab: SettingsTab?) {
        settingsNavigation.show(tab, sheetIsOpen: windows[.settings]?.attachedSheet != nil)
        present(.settings, title: "Settings", size: nil, resizable: false) {
            SettingsRootView(context: context, navigation: settingsNavigation)
        }
    }

    func showOnboarding() {
        present(.onboarding, title: "Set Up Dictation", size: nil, resizable: false) {
            OnboardingView(context: context) { [weak self] in
                self?.windows[.onboarding]?.close()
            }
        }
    }

    // MARK: - Windows

    /// Brings the window of this kind forward, creating it the first time.
    private func present<Content: View>(
        _ kind: Kind,
        title: String,
        size: NSSize?,
        resizable: Bool,
        content: () -> Content
    ) {
        let window = windows[kind] ?? makeWindow(kind, title: title, size: size, resizable: resizable, content: content())
        windows[kind] = window
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow<Content: View>(
        _ kind: Kind,
        title: String,
        size: NSSize?,
        resizable: Bool,
        content: Content
    ) -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: content))
        window.title = title
        window.styleMask = resizable
            ? [.titled, .closable, .miniaturizable, .resizable]
            : [.titled, .closable]
        if let size {
            window.setContentSize(size)
        }
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("LiveTranscribe.\(kind.rawValue)")
        window.identifier = NSUserInterfaceItemIdentifier(kind.rawValue)
        window.delegate = self
        if !window.setFrameUsingName(window.frameAutosaveName) {
            window.center()
        }
        return window
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let kind = windows.first(where: { $0.value === window })?.key
        else { return }
        windows[kind] = nil
        if kind == .transcript {
            // Stops only a transcript that is listening, or about to; never starts one.
            context.transcript.stopListening()
        }
        if windows.isEmpty {
            // Back to the menu bar: no Dock icon while nothing is open.
            NSApp.setActivationPolicy(.accessory)
            Log.ui.debug("Last window closed; back to the menu bar")
        }
    }
}
