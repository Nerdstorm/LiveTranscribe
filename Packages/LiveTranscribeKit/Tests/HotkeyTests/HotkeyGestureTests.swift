import Hotkey
import Testing

@Suite("HotkeyGesture")
struct HotkeyGestureTests {
    private static let tapMaxMs = 300
    private static let windowMs = 300

    private static func gesture(handsFree: Bool = true) -> HotkeyGesture {
        HotkeyGesture(configuration: HotkeyGestureConfiguration(
            tapMaxMs: tapMaxMs,
            doubleTapWindowMs: windowMs,
            handsFreeEnabled: handsFree
        ))
    }

    /// Feeds `steps` (input at a time in ms) and returns the actions of each step.
    private static func run(_ gesture: inout HotkeyGesture, _ steps: [(HotkeyInput, Int)]) -> [[HotkeyAction]] {
        steps.map { gesture.handle($0.0, atMs: $0.1) }
    }

    // MARK: - Push-to-talk

    @Test("A hold of at least tapMaxMs is processed on release", arguments: [300, 301, 5_000])
    func holdIsProcessed(heldMs: Int) {
        var gesture = Self.gesture()
        #expect(Self.run(&gesture, [(.pressed, 0), (.released, heldMs)]) == [[.startRecording], [.stopAndProcess]])
        #expect(!gesture.isRecording)
    }

    @Test func recordingStartsOnPress() {
        var gesture = Self.gesture()
        #expect(gesture.handle(.pressed, atMs: 1_000) == [.startRecording])
        #expect(gesture.isRecording)
        #expect(!gesture.isHandsFree)
    }

    // MARK: - Taps

    @Test("A short tap waits for a second press", arguments: [0, 150, 299])
    func tapSchedulesTheDoubleTapTimer(heldMs: Int) {
        var gesture = Self.gesture()
        #expect(Self.run(&gesture, [(.pressed, 0), (.released, heldMs)]) == [[.startRecording], [.scheduleTimer(ms: Self.windowMs)]])
        #expect(gesture.isRecording, "audio keeps recording in case this is a double tap")
    }

    @Test func aLoneTapIsCancelledWhenTheTimerFires() {
        var gesture = Self.gesture()
        let actions = Self.run(&gesture, [(.pressed, 0), (.released, 100), (.timerFired, 400)])
        #expect(actions.last == [.cancel])
        #expect(!gesture.isRecording)
    }

    @Test func aTapIsCancelledAtOnceWhenHandsFreeIsOff() {
        var gesture = Self.gesture(handsFree: false)
        #expect(Self.run(&gesture, [(.pressed, 0), (.released, 100)]) == [[.startRecording], [.cancel]])
        #expect(!gesture.isRecording)
    }

    @Test func holdStillWorksWhenHandsFreeIsOff() {
        var gesture = Self.gesture(handsFree: false)
        #expect(Self.run(&gesture, [(.pressed, 0), (.released, 800)]) == [[.startRecording], [.stopAndProcess]])
    }

    // MARK: - Hands-free

    @Test("A second press within the window enters hands-free", arguments: [0, 150, 300])
    func doubleTapEntersHandsFree(gapMs: Int) {
        var gesture = Self.gesture()
        let actions = Self.run(&gesture, [(.pressed, 0), (.released, 100), (.pressed, 100 + gapMs)])
        #expect(actions.last == [.enteredHandsFree])
        #expect(gesture.isRecording)
        #expect(gesture.isHandsFree)
    }

    @Test func handsFreeIgnoresTheSecondReleaseAndStopsOnTheNextPress() {
        var gesture = Self.gesture()
        let actions = Self.run(&gesture, [
            (.pressed, 0), (.released, 100), (.pressed, 200), // double tap
            (.released, 2_000), // release of the second press: ignored
            (.pressed, 9_000), // stop on press
            (.released, 9_100), // its release: ignored
        ])
        #expect(actions == [[.startRecording], [.scheduleTimer(ms: 300)], [.enteredHandsFree], [], [.stopAndProcess], []])
        #expect(!gesture.isRecording)
        #expect(!gesture.isHandsFree)
    }

    @Test func aTimerThatFiresAfterEnteringHandsFreeIsIgnored() {
        var gesture = Self.gesture()
        let actions = Self.run(&gesture, [(.pressed, 0), (.released, 100), (.pressed, 200), (.timerFired, 400)])
        #expect(actions.last == [])
        #expect(gesture.isHandsFree)
    }

    @Test func aPressAfterTheWindowCancelsTheTapAndStartsAnew() {
        var gesture = Self.gesture()
        let actions = Self.run(&gesture, [(.pressed, 0), (.released, 100), (.pressed, 401)])
        #expect(actions.last == [.cancel, .startRecording], "the late timer had not arrived yet")
        #expect(gesture.isRecording)
        #expect(!gesture.isHandsFree)
        // The new press behaves like any first press, and the stale timer no longer matters.
        #expect(Self.run(&gesture, [(.timerFired, 402), (.released, 1_000)]) == [[], [.stopAndProcess]])
    }

    /// Timers are never cancelled. A quick double tap, a stop and a new tap all within one window
    /// leave the first tap's timer running; it must not end the new tap's window early.
    @Test func anEarlierTapsTimerDoesNotCutANewWindowShort() {
        var gesture = Self.gesture()
        let actions = Self.run(&gesture, [
            (.pressed, 0), (.released, 50), // timer A, due at 350
            (.pressed, 100), (.released, 150), // hands-free
            (.pressed, 200), (.released, 220), // stop
            (.pressed, 250), (.released, 300), // a new tap: timer B, due at 600
            (.timerFired, 350), // timer A
            (.pressed, 500), // within the new window
        ])
        #expect(actions == [
            [.startRecording], [.scheduleTimer(ms: 300)],
            [.enteredHandsFree], [],
            [.stopAndProcess], [],
            [.startRecording], [.scheduleTimer(ms: 300)],
            [],
            [.enteredHandsFree],
        ])
        #expect(gesture.isHandsFree)
    }

    @Test("The window's own timer ends it, however late", arguments: [300, 301, 2_000])
    func theCurrentTimerEndsTheWindow(delayMs: Int) {
        var gesture = Self.gesture()
        _ = Self.run(&gesture, [(.pressed, 0), (.released, 100)])
        #expect(gesture.handle(.timerFired, atMs: 100 + delayMs) == [.cancel])
        #expect(!gesture.isRecording)
    }

    /// A caller whose timer clock runs slightly ahead of `atMs` must not leave a recording
    /// running: the only pending timer is this tap's, whatever its time says.
    @Test func theOnlyPendingTimerEndsTheWindowEvenIfItLooksEarly() {
        var gesture = Self.gesture()
        _ = Self.run(&gesture, [(.pressed, 0), (.released, 100)])
        #expect(gesture.handle(.timerFired, atMs: 350) == [.cancel])
        #expect(!gesture.isRecording)
    }

    /// If the earlier tap's timer is delivered late, past the new tap's deadline, it ends the
    /// window just as the new tap's own timer would; that timer is then ignored.
    @Test func aLateStaleTimerPastTheNewDeadlineEndsTheWindow() {
        var gesture = Self.gesture()
        _ = Self.run(&gesture, [
            (.pressed, 0), (.released, 50), (.pressed, 100), (.released, 150), // hands-free
            (.pressed, 200), (.released, 220), // stop
            (.pressed, 250), (.released, 300), // a new tap, due at 600
        ])
        #expect(gesture.handle(.timerFired, atMs: 600) == [.cancel])
        #expect(gesture.handle(.timerFired, atMs: 610) == [])
        #expect(!gesture.isRecording)
    }

    // MARK: - Esc

    @Test("Esc cancels in every recording state", arguments: [
        [(HotkeyInput.pressed, 0)],
        [(.pressed, 0), (.released, 100)],
        [(.pressed, 0), (.released, 100), (.pressed, 200)],
        [(.pressed, 0), (.released, 100), (.pressed, 200), (.released, 300)],
    ])
    func escapeCancelsWhileRecording(steps: [(HotkeyInput, Int)]) {
        var gesture = Self.gesture()
        _ = Self.run(&gesture, steps)
        #expect(gesture.isRecording)
        #expect(gesture.handle(.escape, atMs: 5_000) == [.cancel])
        #expect(!gesture.isRecording)
        #expect(!gesture.isHandsFree)
    }

    @Test func escapeWhenIdleIsIgnored() {
        var gesture = Self.gesture()
        #expect(gesture.handle(.escape, atMs: 0) == [])
    }

    @Test func theReleaseAfterAnEscapeIsIgnored() {
        var gesture = Self.gesture()
        #expect(Self.run(&gesture, [(.pressed, 0), (.escape, 500), (.released, 900)]) == [[.startRecording], [.cancel], []])
    }

    // MARK: - Other keys

    @Test func anotherKeyWhileHeldCancels() {
        var gesture = Self.gesture()
        #expect(Self.run(&gesture, [(.pressed, 0), (.otherKey, 500), (.released, 900)]) == [[.startRecording], [.cancel], []])
        #expect(!gesture.isRecording)
    }

    @Test("Other keys are ignored in hands-free", arguments: [
        [(HotkeyInput.pressed, 0), (.released, 100), (.pressed, 200)],
        [(.pressed, 0), (.released, 100), (.pressed, 200), (.released, 300)],
    ])
    func otherKeysAreIgnoredInHandsFree(steps: [(HotkeyInput, Int)]) {
        var gesture = Self.gesture()
        _ = Self.run(&gesture, steps)
        #expect(gesture.handle(.otherKey, atMs: 1_000) == [])
        #expect(gesture.isHandsFree)
    }

    @Test func anotherKeyAfterATapIsIgnored() {
        var gesture = Self.gesture()
        _ = Self.run(&gesture, [(.pressed, 0), (.released, 100)])
        #expect(gesture.handle(.otherKey, atMs: 150) == [])
        #expect(gesture.isRecording)
    }

    // MARK: - Ignored inputs

    @Test("Inputs that make no sense when idle are ignored", arguments: [HotkeyInput.released, .escape, .otherKey, .timerFired])
    func idleIgnores(input: HotkeyInput) {
        var gesture = Self.gesture()
        #expect(gesture.handle(input, atMs: 0) == [])
        #expect(!gesture.isRecording)
    }

    @Test func aRepeatedPressWhileHeldIsIgnored() {
        var gesture = Self.gesture()
        #expect(Self.run(&gesture, [(.pressed, 0), (.pressed, 50), (.timerFired, 60)]) == [[.startRecording], [], []])
    }

    @Test func aRepeatedPressInHandsFreeBeforeTheReleaseIsIgnored() {
        var gesture = Self.gesture()
        let actions = Self.run(&gesture, [(.pressed, 0), (.released, 100), (.pressed, 200), (.pressed, 250)])
        #expect(actions.last == [])
        #expect(gesture.isHandsFree, "only a press after the second release stops hands-free")
    }

    @Test func aReleaseWhileWaitingForTheSecondPressIsIgnored() {
        var gesture = Self.gesture()
        #expect(Self.run(&gesture, [(.pressed, 0), (.released, 100), (.released, 150)]).last == [])
    }

    @Test func resetReturnsToIdleSilently() {
        var gesture = Self.gesture()
        _ = Self.run(&gesture, [(.pressed, 0), (.released, 100), (.pressed, 200)])
        gesture.reset()
        #expect(!gesture.isRecording)
        #expect(!gesture.isHandsFree)
        #expect(gesture.handle(.pressed, atMs: 300) == [.startRecording])
    }

    @Test func negativeTimingsAreClampedToZero() {
        let configuration = HotkeyGestureConfiguration(tapMaxMs: -5, doubleTapWindowMs: -1, handsFreeEnabled: true)
        #expect(configuration.tapMaxMs == 0)
        #expect(configuration.doubleTapWindowMs == 0)
    }
}
