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
@MainActor
final class WindowPresenter: NSObject, DictationWindowActions, NSWindowDelegate {
    private enum Kind: String {
        case transcript, history, settings, onboarding
    }

    private let context: DictationUIContext
    private var windows: [Kind: NSWindow] = [:]

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

    func showSettings(tab: SettingsTab?) {
        if let tab, let window = windows[.settings] {
            // Rebuilt with a new identity, so the tab view starts on the requested tab.
            window.contentViewController = NSHostingController(
                rootView: SettingsRootView(context: context, selection: tab).id(tab)
            )
        }
        present(.settings, title: "Settings", size: nil, resizable: false) {
            SettingsRootView(context: context, selection: tab ?? .general)
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
        if windows.isEmpty {
            // Back to the menu bar: no Dock icon while nothing is open.
            NSApp.setActivationPolicy(.accessory)
            Log.ui.debug("Last window closed; back to the menu bar")
        }
    }
}
