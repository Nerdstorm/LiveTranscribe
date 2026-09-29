import AppKit
import Dictation
import Observation
import SwiftUI

/// The small circle that follows the mouse pointer while dictation is under way: the microphone
/// level while listening, a spinner while transcribing, and a bubble beside it with a short
/// message when something needs the user's attention. It never takes focus or clicks, so the
/// app being dictated into keeps the keyboard and the mouse.
///
/// Create one when the app starts and keep it: it follows the controller for as long as it
/// lives. What it shows is ``HUDState``'s, placement is ``HUDPlacement``'s and VoiceOver
/// announcements are ``HUDAnnouncer``'s; this class only applies them to the panel.
@MainActor
public final class DictationHUD {
    /// What the panel's content, visibility and size depend on.
    private struct Snapshot {
        let phase: DictationController.Phase
        let notice: DictationNotice?
        /// Shown beside the circle during a dictation, which changes the HUD's size.
        let progress: DictationNotice?
    }

    /// What the panel shows while it is visible.
    private struct Shown {
        let state: HUDState
        /// The HUD's size, which the bubble's side does not change.
        let size: CGSize
        var bubbleSide: HUDBubbleSide
    }

    /// How often the HUD catches up with the pointer while it shows: 60 times a second.
    private static let followInterval: TimeInterval = 1.0 / 60

    private let controller: DictationController
    private let panel: NSPanel
    private let hosting: NSHostingView<LiveDictationHUDView>
    private var announcer = HUDAnnouncer()
    /// `nil` while the panel is hidden.
    private var shown: Shown?
    /// Where the pointer was when the HUD was last placed, so a pointer at rest costs nothing.
    private var placedAt: CGPoint?
    /// Runs only while the panel shows.
    private var followTimer: Timer?

    public init(controller: DictationController) {
        self.controller = controller
        // Borderless and non-activating: the panel can never become key or bring the app
        // forward, so the keyboard stays with the app being dictated into. It sits by the
        // pointer, so it ignores the mouse too, and clicks go to what is under it.
        let side = HUDMetrics.circleSquare
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: side, height: side),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none
        hosting = NSHostingView(rootView: LiveDictationHUDView(controller: controller, state: nil, bubbleSide: .trailing))
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting
        observe()
    }

    /// Reads what the HUD depends on, and runs again after any of it changes.
    ///
    /// Only the reads happen inside the tracking closure. Laying out the SwiftUI content there
    /// would also track what the content reads, such as the microphone level, and resize the
    /// panel many times a second; the hosting view redraws the content by itself.
    private func observe() {
        let snapshot = withObservationTracking {
            Snapshot(phase: controller.phase, notice: controller.notice, progress: controller.progressNotice)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        update(snapshot)
    }

    private func update(_ snapshot: Snapshot) {
        if let announcement = announcer.announcement(for: snapshot.notice, phase: snapshot.phase) {
            HUDAnnouncer.post(announcement)
        }
        guard let state = HUDState(phase: snapshot.phase, notice: snapshot.notice, progress: snapshot.progress) else {
            return hide()
        }
        guard state != shown?.state else { return }
        let pointer = NSEvent.mouseLocation
        // Measured on the side the bubble had: the side changes where the bubble is drawn, not
        // the HUD's size.
        let side = shown?.bubbleSide ?? .trailing
        let size = render(state, bubbleSide: side)
        let placement = HUDPlacement.beside(
            pointer: pointer, size: size, circle: HUDMetrics.circleSquare, screens: Self.screens()
        )
        if placement.bubbleSide != side {
            render(state, bubbleSide: placement.bubbleSide)
        }
        shown = Shown(state: state, size: size, bubbleSide: placement.bubbleSide)
        placedAt = pointer
        panel.setFrame(NSRect(origin: placement.origin, size: size), display: true)
        // The window is transparent, so its shadow follows the drawn circle and bubble;
        // recompute it for the new content, or the old outline's shadow stays.
        panel.invalidateShadow()
        panel.orderFrontRegardless()
        startFollowing()
    }

    private func hide() {
        stopFollowing()
        guard shown != nil else { return }
        shown = nil
        placedAt = nil
        panel.orderOut(nil)
        // Nothing to draw, or to animate, while hidden.
        render(nil, bubbleSide: .trailing)
    }

    /// Puts `state` in the panel, with the bubble on `bubbleSide`, and returns the HUD's size.
    @discardableResult
    private func render(_ state: HUDState?, bubbleSide: HUDBubbleSide) -> CGSize {
        // A fresh root view makes the hosting view take the new state now, so the size read next
        // is the new content's rather than the last one's.
        hosting.rootView = LiveDictationHUDView(controller: controller, state: state, bubbleSide: bubbleSide)
        hosting.layoutSubtreeIfNeeded()
        return hosting.fittingSize
    }

    // MARK: - Following the pointer

    /// Starts moving the HUD with the pointer. The timer runs in the common modes, so the HUD
    /// keeps up while a menu is open or something is being dragged.
    private func startFollowing() {
        guard followTimer == nil else { return }
        let timer = Timer(timeInterval: Self.followInterval, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            // It fires on the main run loop, which it was added to.
            MainActor.assumeIsolated { self.followPointer() }
        }
        RunLoop.main.add(timer, forMode: .common)
        followTimer = timer
    }

    private func stopFollowing() {
        followTimer?.invalidate()
        followTimer = nil
    }

    /// Keeps the HUD next to the pointer. The panel moves only when its origin changes, and is
    /// drawn again only when the bubble changes sides.
    private func followPointer() {
        let pointer = NSEvent.mouseLocation
        guard var shown, pointer != placedAt else { return }
        placedAt = pointer
        let placement = HUDPlacement.beside(
            pointer: pointer, size: shown.size, circle: HUDMetrics.circleSquare, screens: Self.screens()
        )
        if placement.bubbleSide != shown.bubbleSide {
            shown.bubbleSide = placement.bubbleSide
            self.shown = shown
            render(shown.state, bubbleSide: shown.bubbleSide)
            panel.setFrame(NSRect(origin: placement.origin, size: shown.size), display: true)
            panel.invalidateShadow()
        } else if panel.frame.origin != placement.origin {
            panel.setFrameOrigin(placement.origin)
        }
    }

    private static func screens() -> [HUDScreen] {
        NSScreen.screens.map { HUDScreen(frame: $0.frame, visibleFrame: $0.visibleFrame) }
    }
}
