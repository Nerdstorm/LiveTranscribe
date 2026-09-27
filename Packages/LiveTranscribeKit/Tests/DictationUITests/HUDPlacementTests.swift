import CoreGraphics
import Dictation
@testable import DictationUI
import Testing

@Suite("HUD placement")
struct HUDPlacementTests {
    /// The circle's square: a 40-point circle with 4 points of shadow room on each side.
    private let circle: CGFloat = 48
    private let circleOnly = CGSize(width: 48, height: 48)
    private let withBubble = CGSize(width: 300, height: 48)
    /// A message on two lines makes the bubble, and so the HUD, taller than the circle's square.
    private let twoLines = CGSize(width: 330, height: 54)
    private let margin = HUDPlacement.margin

    /// A 1440×900 primary display with a 25-point menu bar and no Dock.
    private let primary = HUDScreen(
        frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875)
    )
    /// A 1920×1080 display to the right of the primary, tops aligned (so it reaches below it).
    private let right = HUDScreen(
        frame: CGRect(x: 1440, y: -180, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 1440, y: -180, width: 1920, height: 1055)
    )
    /// A 1920×1080 display above the primary.
    private let above = HUDScreen(
        frame: CGRect(x: 0, y: 900, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 0, y: 900, width: 1920, height: 1055)
    )
    /// A 1920×1080 display below the primary, reaching further left, with its own menu bar and
    /// a 70-point Dock: visible from y -1010 to -25.
    private let below = HUDScreen(
        frame: CGRect(x: -480, y: -1080, width: 1920, height: 1080),
        visibleFrame: CGRect(x: -480, y: -1010, width: 1920, height: 985)
    )
    /// A 1920×1080 display left of the primary, bottoms aligned: all its x are negative.
    private let left = HUDScreen(
        frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1055)
    )

    private func place(_ pointer: CGPoint, _ size: CGSize, screens: [HUDScreen]? = nil) -> HUDPlacement {
        HUDPlacement.beside(
            pointer: pointer, size: size, circle: circle, screens: screens ?? [primary, right, above, below, left]
        )
    }

    // MARK: - Next to the pointer

    @Test func goesBelowAndRightOfThePointer() {
        // The circle's square starts 16 points right of the pointer and 18 below it.
        #expect(place(CGPoint(x: 700, y: 500), circleOnly) == HUDPlacement(origin: CGPoint(x: 716, y: 434), bubbleSide: .trailing))
        #expect(place(CGPoint(x: 700, y: 500), withBubble) == HUDPlacement(origin: CGPoint(x: 716, y: 434), bubbleSide: .trailing))
    }

    @Test func aTwoLineBubbleLeavesTheCircleWhereItWas() {
        // The circle's square is centred in the 54-point HUD, 3 points from its top, so its top
        // stays at 500 - 18.
        let placement = place(CGPoint(x: 700, y: 500), twoLines)
        #expect(placement == HUDPlacement(origin: CGPoint(x: 716, y: 431), bubbleSide: .trailing))
        #expect(placement.origin.y + 3 + circle == CGFloat(500 - 18))
    }

    @Test func flipsLeftNearTheRightEdgeWithTheBubbleOnTheLeadingSide() {
        // 1200 + 16 + 300 is past 1440 - 10: the HUD's right edge goes 16 points left of the pointer.
        let placement = place(CGPoint(x: 1200, y: 500), withBubble)
        #expect(placement == HUDPlacement(origin: CGPoint(x: 1200 - 16 - 300, y: 434), bubbleSide: .leading))
    }

    @Test func flipsLeftOnlyWhenTheHUDWouldCrossTheMargin() {
        // 1366 + 16 + 48 = 1430: the right edge on the margin still fits.
        #expect(place(CGPoint(x: 1366, y: 500), circleOnly).bubbleSide == .trailing)
        #expect(place(CGPoint(x: 1367, y: 500), circleOnly) == HUDPlacement(origin: CGPoint(x: 1367 - 64, y: 434), bubbleSide: .leading))
    }

    @Test func aBubbleCanFlipACircleThatFitsOnItsOwn() {
        let pointer = CGPoint(x: 1300, y: 500)
        #expect(place(pointer, circleOnly).bubbleSide == .trailing)
        #expect(place(pointer, withBubble).bubbleSide == .leading)
    }

    @Test func flipsAboveThePointerNearTheBottom() {
        // 50 - 18 - 48 is below 0 + 10: the circle's square goes 18 points above the pointer.
        let placement = place(CGPoint(x: 700, y: 50), withBubble)
        #expect(placement == HUDPlacement(origin: CGPoint(x: 716, y: 68), bubbleSide: .trailing))
    }

    @Test func flipsAboveOnlyWhenTheHUDWouldCrossTheMargin() {
        // 76 - 18 - 48 = 10: the bottom edge on the margin still fits.
        #expect(place(CGPoint(x: 700, y: 76), circleOnly).origin.y == 10)
        #expect(place(CGPoint(x: 700, y: 75), circleOnly).origin.y == CGFloat(75 + 18))
    }

    @Test func aTwoLineBubbleFlippedAboveLeavesTheCircleAboveThePointer() {
        let placement = place(CGPoint(x: 700, y: 50), twoLines)
        #expect(placement.origin.y == CGFloat(50 + 18 - 3))
        #expect(placement.origin.y + 3 == CGFloat(50 + 18), "the circle's square starts 18 points above the pointer")
    }

    @Test func flipsAboveTheDock() {
        let docked = HUDScreen(frame: primary.frame, visibleFrame: CGRect(x: 0, y: 70, width: 1440, height: 805))
        // 120 - 18 - 48 = 54 would reach into the Dock.
        #expect(place(CGPoint(x: 700, y: 120), withBubble, screens: [docked]).origin.y == CGFloat(120 + 18))
    }

    @Test func flipsLeftAndAboveInTheBottomRightCorner() {
        let placement = place(CGPoint(x: 1400, y: 30), withBubble)
        #expect(placement == HUDPlacement(origin: CGPoint(x: 1400 - 16 - 300, y: 30 + 18), bubbleSide: .leading))
    }

    // MARK: - Displays

    @Test func followsThePointerOntoADisplayToTheRight() {
        // Far past the primary's right edge, but not that display's.
        #expect(place(CGPoint(x: 2000, y: 0), withBubble) == HUDPlacement(origin: CGPoint(x: 2016, y: -66), bubbleSide: .trailing))
        // Flipped at that display's own right edge (3360)...
        #expect(place(CGPoint(x: 3100, y: 0), withBubble) == HUDPlacement(origin: CGPoint(x: 3100 - 316, y: -66), bubbleSide: .leading))
        // ...and above the pointer near its bottom, which is lower than the primary's.
        #expect(place(CGPoint(x: 2000, y: -150), withBubble).origin.y == CGFloat(-150 + 18))
    }

    @Test func followsThePointerOntoADisplayToTheLeft() {
        #expect(place(CGPoint(x: -1000, y: 500), withBubble) == HUDPlacement(origin: CGPoint(x: -984, y: 434), bubbleSide: .trailing))
        // Near its right edge, which the primary's left edge touches, the HUD flips left rather
        // than straddling onto the primary.
        #expect(place(CGPoint(x: -100, y: 500), withBubble) == HUDPlacement(origin: CGPoint(x: -416, y: 434), bubbleSide: .leading))
        // Taller than the primary: the top of the display is under its own menu bar.
        #expect(place(CGPoint(x: -1000, y: 1070), circleOnly).origin.y == CGFloat(1055 - 10 - 48))
        // The shared edge belongs to the display on its right, as NSMouseInRect decides it.
        #expect(HUDPlacement.isPointer(CGPoint(x: 0, y: 400), on: primary.frame))
        #expect(!HUDPlacement.isPointer(CGPoint(x: 0, y: 400), on: left.frame))
    }

    @Test func followsThePointerOntoADisplayAbove() {
        #expect(place(CGPoint(x: 500, y: 1500), withBubble) == HUDPlacement(origin: CGPoint(x: 516, y: 1434), bubbleSide: .trailing))
        // Just above the primary, the HUD stays on the pointer's display, above the pointer,
        // rather than going down onto the primary.
        #expect(place(CGPoint(x: 500, y: 905), withBubble).origin.y == CGFloat(905 + 18))
        // Past the primary's right edge, which is narrower.
        #expect(place(CGPoint(x: 1500, y: 1500), withBubble).bubbleSide == .trailing)
    }

    @Test func followsThePointerOntoADisplayBelow() {
        #expect(place(CGPoint(x: 100, y: -500), withBubble) == HUDPlacement(origin: CGPoint(x: 116, y: -566), bubbleSide: .trailing))
        // Above that display's Dock.
        #expect(place(CGPoint(x: 100, y: -1000), withBubble).origin.y == CGFloat(-1000 + 18))
        // Left of the primary's left edge, where that display reaches.
        #expect(place(CGPoint(x: -400, y: -500), withBubble).origin.x == -384)
    }

    @Test func aPointerAgainstTheTopEdgeOfADisplayIsOnThatDisplay() {
        // AppKit reports the pointer at the top of the primary as y == 900, which is also the
        // bottom edge of the display above. On the primary, the HUD is clamped under its menu
        // bar; on the display above, it would have flipped above the pointer.
        #expect(place(CGPoint(x: 500, y: 900), circleOnly).origin == CGPoint(x: 516, y: 875 - margin - 48))
        #expect(HUDPlacement.isPointer(CGPoint(x: 500, y: 900), on: primary.frame))
        #expect(!HUDPlacement.isPointer(CGPoint(x: 500, y: 900), on: above.frame))
        #expect(!HUDPlacement.isPointer(CGPoint(x: 1440, y: 400), on: primary.frame))
        #expect(HUDPlacement.isPointer(CGPoint(x: 1440, y: 400), on: right.frame))
    }

    @Test func aPointerOnNoDisplayPlacesTheHUDOnThePrimary() {
        let placement = place(CGPoint(x: -5_000, y: 5_000), withBubble)
        #expect(placement.origin == CGPoint(x: margin, y: 875 - margin - 48))
    }

    @Test func noDisplaysGivesTheOrigin() {
        #expect(place(CGPoint(x: 1, y: 1), withBubble, screens: []) == HUDPlacement(origin: .zero, bubbleSide: .trailing))
    }

    // MARK: - Kept on the display

    @Test func staysBelowTheMenuBar() {
        // 895 - 18 - 48 fits below the pointer, but the HUD's top would be under the menu bar.
        #expect(place(CGPoint(x: 700, y: 895), circleOnly).origin.y == 875 - margin - 48)
    }

    @Test func staysOnAShortDisplayWhenFlippedAbove() {
        let short = HUDScreen(frame: CGRect(x: 0, y: 0, width: 400, height: 100), visibleFrame: CGRect(x: 0, y: 0, width: 400, height: 100))
        // Flipped above the pointer to 58, then brought down so its top is 10 points from the display's.
        #expect(place(CGPoint(x: 100, y: 40), circleOnly, screens: [short]).origin.y == 100 - margin - 48)
    }

    @Test func staysOnANarrowDisplayWhenFlippedLeft() {
        let narrow = HUDScreen(frame: CGRect(x: 0, y: 0, width: 400, height: 400), visibleFrame: CGRect(x: 0, y: 0, width: 400, height: 400))
        let placement = place(CGPoint(x: 300, y: 200), withBubble, screens: [narrow])
        #expect(placement == HUDPlacement(origin: CGPoint(x: margin, y: 134), bubbleSide: .leading))
    }

    @Test func aHUDWiderThanTheDisplayKeepsItsLeadingEdgeOnScreen() {
        let tiny = HUDScreen(frame: CGRect(x: 0, y: 0, width: 200, height: 200), visibleFrame: CGRect(x: 0, y: 0, width: 200, height: 200))
        #expect(place(CGPoint(x: 100, y: 100), withBubble, screens: [tiny]).origin.x == margin)
    }
}

@Suite("HUD announcements")
struct HUDAnnouncerTests {
    @Test func announcesEachNoticeOnceWhileItShows() {
        var announcer = HUDAnnouncer()
        #expect(announcer.announcement(for: nil, phase: .idle) == nil)
        #expect(announcer.announcement(for: .nothingHeard, phase: .idle) == "Didn't catch that")
        // Redrawn or moved while the same notice shows.
        #expect(announcer.announcement(for: .nothingHeard, phase: .idle) == nil)
        #expect(announcer.announcement(for: .cancelled, phase: .idle) == "Cancelled")
    }

    @Test func announcesANoticeAgainAfterItWentAway() {
        var announcer = HUDAnnouncer()
        _ = announcer.announcement(for: .nothingToUndo, phase: .idle)
        #expect(announcer.announcement(for: nil, phase: .idle) == nil)
        #expect(announcer.announcement(for: .nothingToUndo, phase: .idle) == "Nothing to undo")
    }

    @Test func announcesTheNoticesTheHUDShowsNoWordsFor() {
        // Nothing on screen says so, which is why VoiceOver has to.
        var announcer = HUDAnnouncer()
        #expect(announcer.announcement(for: .cancelled, phase: .idle) == "Cancelled")
        #expect(announcer.announcement(for: .undone, phase: .idle) == "Restored what you said")
    }

    @Test func detailedNoticesDifferByTheirDetail() {
        var announcer = HUDAnnouncer()
        _ = announcer.announcement(for: .captureFailed("A"), phase: .idle)
        #expect(announcer.announcement(for: .captureFailed("B"), phase: .idle) == "The microphone stopped: B")
    }

    @Test func saysNothingWhileTheMicrophoneIsOpen() {
        var announcer = HUDAnnouncer()
        // A notice still set when the next recording starts is not read into the microphone.
        #expect(announcer.announcement(for: .cancelled, phase: .recording(handsFree: false)) == nil)
        #expect(announcer.announcement(for: .cancelled, phase: .processing) == nil)
        // The HUD shows it only once idle again, and only then is it announced.
        #expect(announcer.announcement(for: .nothingHeard, phase: .idle) == "Didn't catch that")
        // Hidden by a recording and shown again afterwards: a new appearance, announced again.
        #expect(announcer.announcement(for: .nothingHeard, phase: .recording(handsFree: true)) == nil)
        #expect(announcer.announcement(for: .nothingHeard, phase: .idle) == "Didn't catch that")
    }
}
