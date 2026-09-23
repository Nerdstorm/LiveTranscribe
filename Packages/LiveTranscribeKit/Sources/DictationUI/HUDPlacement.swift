import CoreGraphics

/// One display, in AppKit global coordinates: the origin is the bottom-left corner of the
/// primary display (the one with the menu bar) and y grows upwards.
struct HUDScreen: Equatable, Sendable {
    let frame: CGRect
    /// The part not covered by the menu bar and the Dock.
    let visibleFrame: CGRect
}

/// Where the dictation HUD goes: just below the caret, above it when there is no room below,
/// and centred near the bottom of the pointer's display when the caret is unknown.
///
/// Pure, with the displays and the pointer passed in, so multi-display layouts are unit-tested.
enum HUDPlacement {
    /// Gap between the caret and the HUD, and between the HUD and the edge of the display.
    static let margin: CGFloat = 10
    /// Height of the HUD's bottom edge above the Dock when the caret is unknown.
    static let bottomInset: CGFloat = 60

    /// The HUD's window origin, in AppKit coordinates.
    ///
    /// - Parameters:
    ///   - size: the HUD's size.
    ///   - caret: the caret or selection, in Accessibility coordinates (top-left origin on the
    ///     primary display, y grows downwards), as ``InsertionTarget/caretRect`` reports it;
    ///     `nil` when unknown.
    ///   - screens: every display, the primary first, as `NSScreen.screens` lists them.
    ///   - mouse: the pointer, in AppKit coordinates, for when the caret is unknown or off-screen.
    static func origin(for size: CGSize, caret: CGRect?, screens: [HUDScreen], mouse: CGPoint) -> CGPoint {
        guard let primary = screens.first else { return .zero }
        if let caret = caret.flatMap({ appKitRect(fromAccessibility: $0, primary: primary) }),
           let screen = screen(containing: CGPoint(x: caret.midX, y: caret.midY), in: screens) {
            return origin(for: size, near: caret, in: screen.visibleFrame)
        }
        let screen = screens.first { isPointer(mouse, on: $0.frame) } ?? primary
        let visible = screen.visibleFrame
        return CGPoint(
            x: clamped(visible.midX - size.width / 2, visible.minX + margin, visible.maxX - size.width - margin),
            y: clamped(visible.minY + bottomInset, visible.minY + margin, visible.maxY - size.height - margin)
        )
    }

    /// Below the caret if the HUD fits there, otherwise above it, kept inside `visible`.
    private static func origin(for size: CGSize, near caret: CGRect, in visible: CGRect) -> CGPoint {
        let below = caret.minY - margin - size.height
        let above = caret.maxY + margin
        let y = below >= visible.minY + margin ? below : above
        return CGPoint(
            x: clamped(caret.midX - size.width / 2, visible.minX + margin, visible.maxX - size.width - margin),
            y: clamped(y, visible.minY + margin, visible.maxY - size.height - margin)
        )
    }

    /// Flips a rectangle from Accessibility coordinates to AppKit ones. Both spaces span every
    /// display and differ only in where y starts and which way it grows, measured against the
    /// primary display. `nil` for a rectangle that cannot be a caret (null, infinite, or NaN).
    static func appKitRect(fromAccessibility rect: CGRect, primary: HUDScreen) -> CGRect? {
        guard !rect.isNull, !rect.isInfinite,
              [rect.origin.x, rect.origin.y, rect.width, rect.height].allSatisfy(\.isFinite)
        else { return nil }
        return CGRect(x: rect.minX, y: primary.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    private static func screen(containing point: CGPoint, in screens: [HUDScreen]) -> HUDScreen? {
        screens.first { $0.frame.contains(point) }
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
    /// wider than the display keeps its leading edge on screen.
    private static func clamped(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        max(min(value, upper), lower)
    }
}
