import CoreGraphics

/// One display, in AppKit global coordinates: the origin is the bottom-left corner of the
/// primary display (the one with the menu bar) and y grows upwards.
struct HUDScreen: Equatable, Sendable {
    let frame: CGRect
    /// The part not covered by the menu bar and the Dock.
    let visibleFrame: CGRect
}

/// Which side of the HUD's circle its bubble goes on.
enum HUDBubbleSide: Equatable, Sendable {
    /// Right of the circle, while the HUD is right of the pointer.
    case trailing
    /// Left of the circle, while the HUD is flipped to the left of the pointer, so the circle
    /// stays next to the pointer.
    case leading
}

/// Where the dictation HUD goes: its circle just below and to the right of the mouse pointer.
/// Near the right edge of the display it flips to the pointer's left, with the bubble on the
/// circle's left; near the bottom it flips above the pointer. It is always kept on the display.
///
/// Pure, with the displays and the pointer passed in, so multi-display layouts are unit-tested.
struct HUDPlacement: Equatable, Sendable {
    /// The HUD window's origin, in AppKit coordinates.
    let origin: CGPoint
    let bubbleSide: HUDBubbleSide

    /// Between the HUD and the edges of the display's visible frame.
    static let margin: CGFloat = 10
    /// Between the pointer and the circle's square: right of the pointer, or left of it when flipped.
    static let horizontalGap: CGFloat = 16
    /// Between the pointer and the circle's square: below the pointer, or above it when flipped.
    static let verticalGap: CGFloat = 18

    /// Places the HUD next to `pointer`.
    ///
    /// Normally the top-left corner of the circle's square is `horizontalGap` right of the pointer
    /// and `verticalGap` below it. When the HUD would cross the visible frame's right edge (less
    /// the margin) it flips left, its right edge `horizontalGap` left of the pointer, and the
    /// bubble goes on the circle's leading side. When it would cross the bottom it flips up, the
    /// circle's square `verticalGap` above the pointer. Then it is clamped inside the visible
    /// frame, less the margin.
    ///
    /// - Parameters:
    ///   - pointer: the mouse pointer, in AppKit coordinates (`NSEvent.mouseLocation`).
    ///   - size: the HUD's size, the shadow's padding included.
    ///   - circle: the side of the circle's square: its diameter with the shadow's padding on
    ///     both sides. A message on two lines makes the HUD taller than that, with the circle
    ///     centred vertically; the circle, not the HUD's edge, is what is kept by the pointer.
    ///   - screens: every display, the primary first, as `NSScreen.screens` lists them. The
    ///     HUD goes on the pointer's display, or the primary if the pointer is on none.
    static func beside(pointer: CGPoint, size: CGSize, circle: CGFloat, screens: [HUDScreen]) -> HUDPlacement {
        guard let primary = screens.first else { return HUDPlacement(origin: .zero, bubbleSide: .trailing) }
        let visible = (screens.first { isPointer(pointer, on: $0.frame) } ?? primary).visibleFrame
        // How far the circle's square is from the HUD's top and bottom edges.
        let inset = max(0, size.height - circle) / 2

        var bubbleSide = HUDBubbleSide.trailing
        var x = pointer.x + horizontalGap
        if x + size.width > visible.maxX - margin {
            bubbleSide = .leading
            x = pointer.x - horizontalGap - size.width
        }
        var y = pointer.y - verticalGap - circle - inset
        if y < visible.minY + margin {
            y = pointer.y + verticalGap - inset
        }
        let origin = CGPoint(
            x: clamped(x, visible.minX + margin, visible.maxX - size.width - margin),
            y: clamped(y, visible.minY + margin, visible.maxY - size.height - margin)
        )
        return HUDPlacement(origin: origin, bubbleSide: bubbleSide)
    }

    /// Whether the pointer is on the display with `frame`, the way `NSMouseInRect` decides it.
    ///
    /// AppKit reports a pointer pushed against a display's top edge at exactly `maxY`, which
    /// `CGRect.contains` leaves out, so that edge counts and the bottom edge does not. Otherwise
    /// the HUD would jump to the primary display whenever the pointer rests at the top of another.
    static func isPointer(_ point: CGPoint, on frame: CGRect) -> Bool {
        point.x >= frame.minX && point.x < frame.maxX && point.y > frame.minY && point.y <= frame.maxY
    }

    /// `value` kept within `lower...upper`; `lower` wins when the range is empty, so a HUD
    /// wider or taller than the display keeps its leading or bottom edge on screen.
    private static func clamped(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        max(min(value, upper), lower)
    }
}
