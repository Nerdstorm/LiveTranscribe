import CoreGraphics
import Dictation
@testable import DictationUI
import Testing

@Suite("HUD placement")
struct HUDPlacementTests {
    private let size = CGSize(width: 300, height: 44)
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
    /// A 1920×1080 display above the primary: Accessibility y is negative on it.
    private let above = HUDScreen(
        frame: CGRect(x: 0, y: 900, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 0, y: 900, width: 1920, height: 1055)
    )
    private let nowhere = CGPoint(x: -5_000, y: -5_000)

    private func origin(caret: CGRect?, screens: [HUDScreen]? = nil, mouse: CGPoint? = nil) -> CGPoint {
        HUDPlacement.origin(for: size, caret: caret, screens: screens ?? [primary, right, above], mouse: mouse ?? nowhere)
    }

    @Test func goesJustBelowTheCaretCentredOnIt() {
        // Accessibility y 400...418 is AppKit y 482...500 on a 900-point primary display.
        let point = origin(caret: CGRect(x: 700, y: 400, width: 2, height: 18))
        #expect(point == CGPoint(x: 701 - 150, y: 482 - margin - 44))
    }

    @Test func flipsAboveTheCaretNearTheBottom() {
        // AppKit y 32...50: no room below.
        let point = origin(caret: CGRect(x: 700, y: 850, width: 2, height: 18))
        #expect(point.y == 50 + margin)
    }

    @Test func flipsAboveTheDock() {
        let docked = HUDScreen(frame: primary.frame, visibleFrame: CGRect(x: 0, y: 70, width: 1440, height: 805))
        // AppKit y 120...138: below would reach into the Dock.
        let point = origin(caret: CGRect(x: 700, y: 762, width: 2, height: 18), screens: [docked])
        #expect(point.y == 138 + margin)
    }

    @Test func staysInsideTheLeftAndRightEdges() {
        #expect(origin(caret: CGRect(x: 2, y: 400, width: 2, height: 18)).x == margin)
        #expect(origin(caret: CGRect(x: 1436, y: 400, width: 2, height: 18)).x == 1440 - 300 - margin)
    }

    @Test func aSelectionTallerThanTheScreenKeepsTheHUDBelowTheMenuBar() {
        let point = origin(caret: CGRect(x: 100, y: 0, width: 400, height: 900), screens: [primary])
        #expect(point.y == 875 - 44 - margin)
        #expect(point.x == CGFloat(300 - 150))
    }

    @Test func usesTheSecondaryDisplayTheCaretIsOn() {
        // Accessibility y 500...518 is AppKit y 382...400, on the display to the right.
        let point = origin(caret: CGRect(x: 2000, y: 500, width: 2, height: 18))
        #expect(point == CGPoint(x: 2001 - 150, y: 382 - margin - 44))
        // Clamped to that display's right edge, not the primary's.
        #expect(origin(caret: CGRect(x: 3355, y: 500, width: 2, height: 18)).x == 3360 - 300 - margin)
    }

    @Test func handlesADisplayAboveThePrimary() {
        // Accessibility y -600...-582 is AppKit y 1482...1500.
        let point = origin(caret: CGRect(x: 500, y: -600, width: 2, height: 18))
        #expect(point == CGPoint(x: 501 - 150, y: 1482 - margin - 44))
    }

    @Test func withoutACaretSitsAtTheBottomOfThePointersDisplay() {
        let point = origin(caret: nil, mouse: CGPoint(x: 2000, y: 0))
        #expect(point == CGPoint(x: right.visibleFrame.midX - 150, y: right.visibleFrame.minY + HUDPlacement.bottomInset))
    }

    @Test func aPointerAgainstTheTopEdgeOfADisplayIsOnThatDisplay() {
        // AppKit reports the pointer at the top of the right display as y == 900, its maxY.
        let point = origin(caret: nil, mouse: CGPoint(x: 2000, y: 900))
        #expect(point == CGPoint(x: right.visibleFrame.midX - 150, y: right.visibleFrame.minY + HUDPlacement.bottomInset))
        // The shared edge between the primary and the display above belongs to the primary.
        #expect(HUDPlacement.isPointer(CGPoint(x: 500, y: 900), on: primary.frame))
        #expect(!HUDPlacement.isPointer(CGPoint(x: 500, y: 900), on: above.frame))
        #expect(!HUDPlacement.isPointer(CGPoint(x: 1440, y: 400), on: primary.frame))
    }

    @Test func withoutACaretOrAPointerOnScreenUsesThePrimaryDisplay() {
        let point = origin(caret: nil)
        #expect(point == CGPoint(x: 720 - 150, y: HUDPlacement.bottomInset))
    }

    @Test func aCaretOffEveryDisplayOrUnusableIsTreatedAsUnknown() {
        let mouse = CGPoint(x: 2000, y: 0)
        let expected = origin(caret: nil, mouse: mouse)
        #expect(origin(caret: CGRect(x: -9_000, y: 400, width: 2, height: 18), mouse: mouse) == expected)
        #expect(origin(caret: .infinite, mouse: mouse) == expected)
        #expect(origin(caret: .null, mouse: mouse) == expected)
        #expect(origin(caret: CGRect(x: CGFloat.nan, y: 400, width: 2, height: 18), mouse: mouse) == expected)
    }

    @Test func noDisplaysGivesTheOrigin() {
        #expect(origin(caret: CGRect(x: 1, y: 1, width: 1, height: 1), screens: []) == .zero)
    }

    @Test func aHUDWiderThanTheDisplayKeepsItsLeadingEdgeOnScreen() {
        let narrow = HUDScreen(frame: CGRect(x: 0, y: 0, width: 200, height: 200), visibleFrame: CGRect(x: 0, y: 0, width: 200, height: 200))
        let point = HUDPlacement.origin(for: size, caret: nil, screens: [narrow], mouse: .zero)
        #expect(point.x == margin)
    }

    @Test func flipsAccessibilityRectanglesAgainstThePrimaryDisplay() {
        let rect = HUDPlacement.appKitRect(fromAccessibility: CGRect(x: 10, y: 20, width: 5, height: 30), primary: primary)
        #expect(rect == CGRect(x: 10, y: 900 - 50, width: 5, height: 30))
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
