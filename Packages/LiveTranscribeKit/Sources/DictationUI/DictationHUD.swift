import AppKit
import Dictation
import Observation
import SwiftUI

/// The floating capsule that shows dictation state near the caret: listening, transcribing, or
/// a short message. It never takes focus, so the app being dictated into keeps the keyboard.
///
/// Create one when the app starts and keep it: it follows the controller for as long as it
/// lives. Placement is ``HUDPlacement``'s and VoiceOver announcements are ``HUDAnnouncer``'s;
/// this class only applies them to the panel.
@MainActor
public final class DictationHUD {
    /// What the panel's visibility, size and position depend on.
    private struct Snapshot {
        let phase: DictationController.Phase
        let notice: DictationNotice?
        let caret: CGRect?
        /// Changes the hint's text, and so the HUD's width.
        let hotkey: HotkeyState

        var isVisible: Bool { phase != .idle || notice != nil }
    }

    private let controller: DictationController
    private let panel: NSPanel
    private let hosting: NSHostingView<DictationHUDView>
    private var announcer = HUDAnnouncer()

    public init(controller: DictationController) {
        self.controller = controller
        // Borderless and non-activating: the panel can never become key or bring the app
        // forward, so the keyboard stays with the app being dictated into.
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 44),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none
        hosting = NSHostingView(rootView: DictationHUDView(controller: controller))
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting
        observe()
    }

    /// Reads what the HUD depends on, and runs again after any of it changes.
    ///
    /// Only the reads happen inside the tracking closure. Laying out the SwiftUI content there
    /// would also track what the content reads, such as the microphone level, and move the panel
    /// many times a second; the hosting view redraws the content by itself.
    private func observe() {
        let snapshot = withObservationTracking {
            Snapshot(
                phase: controller.phase,
                notice: controller.notice,
                caret: controller.caretRect,
                hotkey: controller.hotkeyState
            )
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        update(snapshot)
    }

    private func update(_ state: Snapshot) {
        if let announcement = announcer.announcement(for: state.notice, phase: state.phase) {
            HUDAnnouncer.post(announcement)
        }
        guard state.isVisible else {
            panel.orderOut(nil)
            return
        }
        // A fresh root view makes the hosting view take the new state now, so the size read next
        // is the new content's rather than the last one's.
        hosting.rootView = DictationHUDView(controller: controller)
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let origin = HUDPlacement.origin(
            for: size,
            caret: state.caret,
            screens: NSScreen.screens.map { HUDScreen(frame: $0.frame, visibleFrame: $0.visibleFrame) },
            mouse: NSEvent.mouseLocation
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        // The window is transparent, so its shadow follows the drawn capsule; recompute it for
        // the new content, or the old outline's shadow stays.
        panel.invalidateShadow()
        panel.orderFrontRegardless()
    }
}
