import AppKit
@testable import DictationUI
import SwiftUI
import Testing

/// Measures ``HUDWidthLimit`` the way ``DictationHUD`` does: an `NSHostingView`'s fitting size,
/// at the ideal size. Nothing is put in a window.
@MainActor
@Suite("HUD message width")
struct HUDWidthLimitTests {
    private let limit: CGFloat = 200

    private func fittingSize(_ message: String) -> CGSize {
        let view = HUDWidthLimit(maxWidth: limit) {
            Text(message).lineLimit(2)
        }
        .fixedSize()
        let hosting = NSHostingView(rootView: view)
        hosting.layoutSubtreeIfNeeded()
        return hosting.fittingSize
    }

    @Test func aShortMessageKeepsItsOwnWidth() {
        let size = fittingSize("Cancelled")
        #expect(size.width > 0)
        #expect(size.width < limit)
    }

    @Test func aLongMessageWrapsAndIsMeasuredTaller() {
        let oneLine = fittingSize("Cancelled")
        let long = fittingSize("What you said is on the clipboard: select the edit and press ⌘V to paste it back")
        #expect(long.width <= limit)
        // Measured on two lines, so the capsule around it is tall enough to hold them.
        #expect(long.height > oneLine.height * 1.5)
    }
}
