import Dictation
import SwiftUI

/// The HUD's sizes, in points.
enum HUDMetrics {
    /// The circle's diameter.
    static let circle: CGFloat = 40
    /// Transparent room around what is drawn, for the window's shadow.
    static let shadowPadding: CGFloat = 4
    /// The circle with the shadow's room on both sides: the square ``HUDPlacement`` keeps next
    /// to the pointer, and the whole HUD while there is no bubble.
    static let circleSquare: CGFloat = circle + 2 * shadowPadding
    /// The ring a hands-free recording adds, just inside the circle's edge.
    static let ringRadius: CGFloat = 17.5
    static let ringWidth: CGFloat = 1.5
    /// The transcribing spinner: three quarters of a ring, turning once every `spinnerPeriod`
    /// seconds.
    static let spinnerRadius: CGFloat = 8
    static let spinnerWidth: CGFloat = 2
    static let spinnerArc: CGFloat = 0.75
    static let spinnerPeriod: TimeInterval = 1
    /// The glyph for a notice between dictations.
    static let glyph: CGFloat = 22
    /// Between the circle and the bubble.
    static let bubbleGap: CGFloat = 8
    /// Widest a message gets before it wraps onto a second line.
    static let bubbleMaxWidth: CGFloat = 260
    static let bubbleCornerRadius: CGFloat = 12
}

/// The HUD: a circle with the microphone level, a spinner or a glyph, and beside it a bubble
/// with a message when there is one. It has no words of its own and no buttons: Esc and the
/// menu bar's *Cancel Dictation* cancel.
struct DictationHUDView: View {
    let state: HUDState
    /// The microphone level, 0...1, drawn while recording.
    let level: Float
    let bubbleSide: HUDBubbleSide

    var body: some View {
        HStack(spacing: HUDMetrics.bubbleGap) {
            if bubbleSide == .leading { bubble }
            circle
            if bubbleSide == .trailing { bubble }
        }
        .fixedSize()
        // Room for the window shadow around the circle and the bubble.
        .padding(HUDMetrics.shadowPadding)
    }

    private var circle: some View {
        indicator
            .frame(width: HUDMetrics.circle, height: HUDMetrics.circle)
            .background(.regularMaterial, in: Circle())
            .overlay(Circle().strokeBorder(.quaternary))
    }

    @ViewBuilder private var indicator: some View {
        switch state.indicator {
        case .level(let handsFree):
            let radius = HUDLevel.discRadius(level)
            ZStack {
                if handsFree {
                    Circle()
                        .stroke(.secondary, lineWidth: HUDMetrics.ringWidth)
                        .frame(width: 2 * HUDMetrics.ringRadius, height: 2 * HUDMetrics.ringRadius)
                }
                Circle()
                    .fill(.red)
                    .frame(width: 2 * radius, height: 2 * radius)
                    .animation(.easeOut(duration: 0.1), value: level)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(handsFree ? "Listening, hands-free" : "Listening")
        case .spinner:
            HUDSpinner()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Transcribing")
        case .notice(let isProblem):
            Image(systemName: isProblem ? "exclamationmark.circle.fill" : "info.circle.fill")
                .font(.system(size: HUDMetrics.glyph))
                .foregroundStyle(isProblem ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder private var bubble: some View {
        if let message = state.message {
            HUDWidthLimit(maxWidth: HUDMetrics.bubbleMaxWidth) {
                Text(message)
                    .lineLimit(2)
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: HUDMetrics.bubbleCornerRadius))
            .overlay(RoundedRectangle(cornerRadius: HUDMetrics.bubbleCornerRadius).strokeBorder(.quaternary))
        }
    }
}

/// The transcribing spinner: three quarters of a ring, turning clockwise once a second. Its angle
/// comes from the clock rather than from an animation, so it is the same whenever it is drawn.
struct HUDSpinner: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60)) { context in
            Circle()
                .trim(from: 0, to: HUDMetrics.spinnerArc)
                .stroke(.secondary, style: StrokeStyle(lineWidth: HUDMetrics.spinnerWidth, lineCap: .round))
                .frame(width: 2 * HUDMetrics.spinnerRadius, height: 2 * HUDMetrics.spinnerRadius)
                .rotationEffect(Self.angle(at: context.date.timeIntervalSinceReferenceDate))
        }
    }

    /// How far the ring has turned at `time`, in seconds: a whole turn every
    /// ``HUDMetrics/spinnerPeriod``. SwiftUI's y axis points down, so a growing angle turns it
    /// clockwise.
    nonisolated static func angle(at time: TimeInterval) -> Angle {
        let turns = time / HUDMetrics.spinnerPeriod
        return .degrees(360 * (turns - turns.rounded(.down)))
    }
}

/// The panel's content: ``DictationHUDView`` with the controller's microphone level, which
/// changes many times a second. The hosting view redraws for it by itself, without the panel
/// being measured or moved. Draws nothing without a state, so nothing animates while hidden.
struct LiveDictationHUDView: View {
    let controller: DictationController
    let state: HUDState?
    let bubbleSide: HUDBubbleSide

    var body: some View {
        if let state {
            DictationHUDView(state: state, level: controller.inputLevel, bubbleSide: bubbleSide)
        }
    }
}

/// Lays out its one subview at most `maxWidth` wide: a short text keeps its own width, a long one
/// wraps and grows taller.
///
/// The HUD is measured at its ideal size (`fixedSize`), and an ideal-size measurement offers no
/// width. `.frame(maxWidth:)` then passes "no width" on, so a text is measured on one line and
/// only drawn wrapped, spilling out of a bubble sized for one line. This offers the text the
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
