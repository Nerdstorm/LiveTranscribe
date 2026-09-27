import CoreGraphics
import Dictation
@testable import DictationUI
import Testing

/// What the HUD shows: wordless while dictating, and a bubble only for a notice that needs
/// attention.
@Suite("HUD state")
struct HUDStateTests {
    private static let airPods = DictationNotice.microphone("Now using AirPods.")

    @Test func aRecordingIsWordless() {
        #expect(HUDState(phase: .recording(handsFree: false), notice: nil, progress: nil)
            == HUDState(indicator: .level(handsFree: false), message: nil))
        #expect(HUDState(phase: .recording(handsFree: true), notice: nil, progress: nil)
            == HUDState(indicator: .level(handsFree: true), message: nil))
    }

    @Test func transcribingIsWordless() {
        #expect(HUDState(phase: .processing, notice: nil, progress: nil) == HUDState(indicator: .spinner, message: nil))
    }

    @Test func aProgressNoticeShowsInTheBubbleDuringADictation() {
        #expect(HUDState(phase: .recording(handsFree: false), notice: nil, progress: Self.airPods)
            == HUDState(indicator: .level(handsFree: false), message: "Now using AirPods."))
        #expect(HUDState(phase: .processing, notice: nil, progress: .stillProcessing)
            == HUDState(indicator: .spinner, message: DictationNotice.stillProcessing.message))
    }

    @Test func theLastDictationsNoticeIsNotShownDuringTheNext() {
        #expect(HUDState(phase: .recording(handsFree: false), notice: .nothingHeard, progress: nil)?.message == nil)
        #expect(HUDState(phase: .processing, notice: .insertionFailed, progress: nil)?.message == nil)
    }

    @Test func aProblemBetweenDictationsShowsAWarningAndItsMessage() {
        #expect(HUDState(phase: .idle, notice: .insertionFailed, progress: nil)
            == HUDState(indicator: .notice(isProblem: true), message: "The text couldn't be inserted or copied"))
    }

    @Test func otherNoticesBetweenDictationsShowAnInfoGlyphAndTheirMessage() {
        #expect(HUDState(phase: .idle, notice: .nothingHeard, progress: nil)
            == HUDState(indicator: .notice(isProblem: false), message: "Didn't catch that"))
        #expect(HUDState(phase: .idle, notice: Self.airPods, progress: nil)
            == HUDState(indicator: .notice(isProblem: false), message: "Now using AirPods."))
    }

    @Test("A cancel, or an undo that worked, hides the HUD", arguments: [DictationNotice.cancelled, .undone])
    func aNoticeThatNeedsNoWordsHidesTheHUD(notice: DictationNotice) {
        #expect(HUDState(phase: .idle, notice: notice, progress: nil) == nil)
    }

    @Test func nothingToSayBetweenDictationsHidesTheHUD() {
        #expect(HUDState(phase: .idle, notice: nil, progress: nil) == nil)
        // A progress notice belongs to a dictation; between dictations the controller shows it
        // as its notice instead.
        #expect(HUDState(phase: .idle, notice: nil, progress: Self.airPods) == nil)
    }
}

/// The red disc: 6 points across in silence, 16 at the loudest, on a log scale between the
/// five-bar meter's first and last thresholds.
@Suite("HUD level")
struct HUDLevelTests {
    @Test("The disc's radius at the ends of the scale and beyond", arguments: [
        (Float(0), CGFloat(6)),
        (-1, 6),
        (.nan, 6),
        (0.001, 6),
        (0.005, 6),
        (0.12, 16),
        (0.5, 16),
        (.infinity, 16),
    ])
    func discRadius(level: Float, radius: CGFloat) {
        #expect(HUDLevel.discRadius(level) == radius)
    }

    @Test func halfwayOnTheLogScaleIsHalfTheGrowth() {
        // The geometric mean of 0.005 and 0.12.
        let middle = Float((0.005 * 0.12).squareRoot())
        #expect(abs(HUDLevel.fraction(middle) - 0.5) < 1e-5)
        #expect(abs(HUDLevel.discRadius(middle) - 11) < 1e-4)
    }

    @Test func aLouderLevelIsNeverASmallerDisc() {
        let levels = stride(from: Float(0), through: 0.2, by: 0.001)
        let radii = levels.map(HUDLevel.discRadius)
        #expect(zip(radii, radii.dropFirst()).allSatisfy { $0 <= $1 })
    }
}
