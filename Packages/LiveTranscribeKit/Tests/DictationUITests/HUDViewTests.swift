import AppKit
import Dictation
@testable import DictationUI
import SwiftUI
import Testing

/// Measures the HUD the way ``DictationHUD`` sizes its panel: an `NSHostingView`'s fitting
/// size, at the ideal size. Nothing is put in a window.
@MainActor
@Suite("HUD size")
struct HUDViewTests {
    private func fittingSize(_ state: HUDState, side: HUDBubbleSide = .trailing) -> CGSize {
        let hosting = NSHostingView(rootView: DictationHUDView(state: state, level: 0.05, bubbleSide: side))
        hosting.layoutSubtreeIfNeeded()
        return hosting.fittingSize
    }

    @Test("Without a bubble the HUD is the circle's square", arguments: [
        HUDState(indicator: .level(handsFree: false), message: nil),
        HUDState(indicator: .level(handsFree: true), message: nil),
        HUDState(indicator: .spinner, message: nil),
    ])
    func withoutABubble(state: HUDState) {
        #expect(fittingSize(state) == CGSize(width: HUDMetrics.circleSquare, height: HUDMetrics.circleSquare))
    }

    @Test func theCirclesSquareIsTheCircleWithTheShadowsRoomAround() {
        #expect(HUDMetrics.circleSquare == CGFloat(40 + 2 * 4))
    }

    @Test func aOneLineBubbleIsNoTallerThanTheCircle() {
        let size = fittingSize(HUDState(indicator: .notice(isProblem: false), message: "Didn't catch that"))
        #expect(size.height == HUDMetrics.circleSquare)
        #expect(size.width > HUDMetrics.circleSquare + HUDMetrics.bubbleGap + 24)
    }

    @Test func aLongMessageWrapsInsideTheBubblesWidth() {
        let message = DictationNotice.pasteNotAllowed(needsReopen: true).message
        let size = fittingSize(HUDState(indicator: .notice(isProblem: true), message: message))
        // The circle's square, the gap, and the bubble: at most 260 of text and 12 of padding each side.
        #expect(size.width <= HUDMetrics.circleSquare + HUDMetrics.bubbleGap + HUDMetrics.bubbleMaxWidth + 24)
        #expect(size.height > HUDMetrics.circleSquare, "two lines make the bubble taller than the circle")
    }

    @Test func theBubblesSideDoesNotChangeTheSize() {
        let state = HUDState(indicator: .notice(isProblem: true), message: DictationNotice.insertionFailed.message)
        #expect(fittingSize(state, side: .leading) == fittingSize(state, side: .trailing))
    }
}

/// The transcribing spinner turns once a second, clockwise, by the clock.
@Suite("HUD spinner")
struct HUDSpinnerTests {
    @Test("A whole turn every second", arguments: [
        (0.0, 0.0), (0.25, 90), (0.5, 180), (0.75, 270), (1, 0), (1.25, 90), (12_345.5, 180),
    ])
    func angle(time: Double, degrees: Double) {
        #expect(HUDSpinner.angle(at: time).degrees == degrees)
    }

    @Test func turnsOneWayWithinASecond() {
        // A growing angle is clockwise on screen: SwiftUI's y axis points down.
        let angles = stride(from: 0.0, to: 1, by: 0.05).map { HUDSpinner.angle(at: 100 + $0).degrees }
        #expect(zip(angles, angles.dropFirst()).allSatisfy { $0 < $1 })
    }
}
