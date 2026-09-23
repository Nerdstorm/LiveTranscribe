import Dictation
import SwiftUI

/// The HUD's capsule: the microphone level and a hint while listening, a spinner while
/// transcribing, or the latest message. A message about the dictation in progress (a change of
/// microphone, a press while transcribing) takes the hint's line for a while.
struct DictationHUDView: View {
    /// Widest a message gets before it wraps onto a second line.
    static let messageMaxWidth: CGFloat = 320

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
        // Room for the window shadow around the capsule.
        .padding(4)
    }

    @ViewBuilder private var content: some View {
        switch controller.phase {
        case .recording(let handsFree):
            HUDLevelMeter(level: controller.inputLevel)
            VStack(alignment: .leading, spacing: 1) {
                Text(handsFree ? "Listening, hands-free" : "Listening")
                caption(Self.recordingCaption(
                    progress: controller.progressNotice, hotkeyState: controller.hotkeyState, handsFree: handsFree
                ))
            }
            .accessibilityElement(children: .combine)
            cancelButton
        case .processing:
            ProgressView()
                .controlSize(.small)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Transcribing…")
                if let progress = controller.progressNotice {
                    caption(progress.message)
                }
            }
            .accessibilityElement(children: .combine)
            cancelButton
        case .idle:
            if let notice = controller.notice {
                Image(systemName: notice.isProblem ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(notice.isProblem ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .accessibilityHidden(true)
                HUDWidthLimit(maxWidth: Self.messageMaxWidth) {
                    Text(notice.message)
                        .lineLimit(2)
                }
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
        .help(Self.cancelHelp(hotkeyState: controller.hotkeyState))
        .accessibilityLabel("Cancel dictation")
    }

    /// The line under a title: the hint, or a progress notice, which can be long enough to wrap.
    private func caption(_ text: String) -> some View {
        HUDWidthLimit(maxWidth: Self.messageMaxWidth) {
            Text(text)
                .lineLimit(2)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    /// The line under *Listening*: the latest progress notice while it shows, otherwise the hint.
    static func recordingCaption(progress: DictationNotice?, hotkeyState: HotkeyState, handsFree: Bool) -> String {
        progress?.message ?? hint(hotkeyState: hotkeyState, handsFree: handsFree)
    }

    /// How to finish and cancel. Esc is caught only by the shortcut's keyboard tap, which runs
    /// only while the state is ``HotkeyState/running(hotkey:)``. In any other state (dictation
    /// turned off, no Accessibility, a tap that failed) the dictation was started from the menu
    /// and Esc would go to the app in front, so the hint names the menu and the × button.
    static func hint(hotkeyState: HotkeyState, handsFree: Bool) -> String {
        guard case .running(let hotkey) = hotkeyState else { return "Finish from the menu bar · × to cancel" }
        return handsFree ? "Press \(hotkey) to finish · esc to cancel" : "Release \(hotkey) to finish · esc to cancel"
    }

    /// The cancel button's tooltip, which names Esc only while Esc cancels; see
    /// ``hint(hotkeyState:handsFree:)``.
    static func cancelHelp(hotkeyState: HotkeyState) -> String {
        if case .running = hotkeyState { "Cancel (esc)" } else { "Cancel" }
    }
}

/// Five bars that rise with the microphone level.
private struct HUDLevelMeter: View {
    let level: Float
    /// Level at which each bar lights, for a meter that moves with normal speech.
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

/// Lays out its one subview at most `maxWidth` wide: a short text keeps its own width, a long one
/// wraps and grows taller.
///
/// The HUD is measured at its ideal size (`fixedSize`), and an ideal-size measurement offers no
/// width. `.frame(maxWidth:)` then passes "no width" on, so a text is measured on one line and
/// only drawn wrapped, spilling out of a capsule sized for one line. This offers the text the
/// width instead, so it is measured the way it is drawn.
struct HUDWidthLimit: Layout {
    let maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        return subview.sizeThatFits(ProposedViewSize(width: min(proposal.width ?? maxWidth, maxWidth), height: nil))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
    }
}
