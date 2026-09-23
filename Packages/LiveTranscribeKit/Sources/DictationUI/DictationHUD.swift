import AppKit
import Dictation
import Observation
import Shared
import SwiftUI

/// The floating capsule that shows dictation state near the caret: listening, transcribing, or
/// a short message. It never takes focus, so the app being dictated into keeps the keyboard.
@MainActor
public final class DictationHUD {
    private let controller: DictationController
    private let panel: NSPanel
    /// Gap between the caret and the HUD, and between the HUD and the screen edge.
    private static let margin: CGFloat = 10
    private var lastAnnouncement: DictationNotice?

    public init(controller: DictationController) {
        self.controller = controller
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
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = true
        let hosting = NSHostingView(rootView: DictationHUDView(controller: controller))
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting
        observe()
    }

    /// Re-runs whenever a property the HUD depends on changes.
    private func observe() {
        withObservationTracking {
            update(phase: controller.phase, notice: controller.notice, caret: controller.caretRect)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    private func update(phase: DictationController.Phase, notice: DictationNotice?, caret: CGRect?) {
        announce(notice)
        guard phase != .idle || notice != nil else {
            panel.orderOut(nil)
            return
        }
        panel.contentView?.layoutSubtreeIfNeeded()
        let size = panel.contentView?.fittingSize ?? panel.frame.size
        panel.setFrame(NSRect(origin: Self.origin(for: size, caret: caret), size: size), display: true)
        panel.orderFrontRegardless()
    }

    /// Below the caret when it is known and there is room, otherwise above it; without a caret,
    /// centred near the bottom of the screen with the pointer.
    static func origin(for size: CGSize, caret: CGRect?) -> CGPoint {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        if let caret {
            // Accessibility uses a top-left origin on the primary screen; AppKit a bottom-left one.
            let caretBottom = primaryHeight - caret.maxY
            let caretTop = primaryHeight - caret.minY
            let point = CGPoint(x: caret.midX, y: caretBottom)
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) {
                let visible = screen.visibleFrame
                var origin = CGPoint(x: caret.midX - size.width / 2, y: caretBottom - margin - size.height)
                if origin.y < visible.minY { origin.y = caretTop + margin }
                origin.x = min(max(origin.x, visible.minX + margin), visible.maxX - size.width - margin)
                origin.y = min(max(origin.y, visible.minY + margin), visible.maxY - size.height - margin)
                return origin
            }
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        return CGPoint(x: visible.midX - size.width / 2, y: visible.minY + 6 * margin)
    }

    /// VoiceOver users hear messages the HUD shows.
    private func announce(_ notice: DictationNotice?) {
        guard let notice, notice != lastAnnouncement else {
            lastAnnouncement = notice
            return
        }
        lastAnnouncement = notice
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: notice.message, .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )
    }
}

struct DictationHUDView: View {
    let controller: DictationController

    var body: some View {
        HStack(spacing: 10) {
            content
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minWidth: 180)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.quaternary))
        .fixedSize()
        .padding(4)
    }

    @ViewBuilder private var content: some View {
        switch controller.phase {
        case .recording(let handsFree):
            LevelMeter(level: controller.inputLevel)
            VStack(alignment: .leading, spacing: 1) {
                Text(handsFree ? "Listening, hands-free" : "Listening")
                Text(hint(handsFree: handsFree))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            cancelButton
        case .processing:
            ProgressView().controlSize(.small)
            Text("Transcribing…")
            cancelButton
        case .idle:
            if let notice = controller.notice {
                Image(systemName: notice.isProblem ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(notice.isProblem ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                Text(notice.message)
                    .lineLimit(2)
                    .frame(maxWidth: 320, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var cancelButton: some View {
        Button {
            controller.cancel()
        } label: {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Cancel (esc)")
        .accessibilityLabel("Cancel dictation")
    }

    private func hint(handsFree: Bool) -> String {
        guard case .running(let hotkey) = controller.hotkeyState else { return "esc to cancel" }
        return handsFree ? "Press \(hotkey) to finish · esc to cancel" : "Release \(hotkey) to finish · esc to cancel"
    }
}

/// Five bars that rise with the microphone level.
private struct LevelMeter: View {
    let level: Float
    private let thresholds: [Float] = [0.005, 0.015, 0.03, 0.06, 0.12]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(thresholds.indices, id: \.self) { index in
                Capsule()
                    .fill(level >= thresholds[index] ? AnyShapeStyle(.red) : AnyShapeStyle(.quaternary))
                    .frame(width: 3, height: CGFloat(6 + index * 3))
            }
        }
        .frame(height: 18)
        .animation(.easeOut(duration: 0.1), value: level)
        .accessibilityHidden(true)
    }
}
