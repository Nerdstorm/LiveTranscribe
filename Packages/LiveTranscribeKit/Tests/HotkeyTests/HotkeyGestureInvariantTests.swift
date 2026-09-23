import Hotkey
import Testing

/// Properties that must hold for any input sequence, not just the scripted ones.
@Suite("HotkeyGesture invariants")
struct HotkeyGestureInvariantTests {
    /// Random input sequences never start recording twice without a stop or cancel between, and
    /// `isRecording` always agrees with the actions emitted so far.
    @Test("Never starts twice without a stop or cancel", arguments: 0..<20)
    func neverStartsTwice(seed: UInt64) {
        var random = SplitMix64(seed: seed)
        let inputs: [HotkeyInput] = [.pressed, .released, .escape, .otherKey, .timerFired]
        var gesture = Self.gesture(handsFree: seed % 2 == 0)
        var recording = false
        var now = 0
        for _ in 0..<500 {
            now += Int(random.next() % 700)
            let input = inputs[Int(random.next() % UInt64(inputs.count))]
            for action in gesture.handle(input, atMs: now) {
                switch action {
                case .startRecording:
                    #expect(!recording, "startRecording while already recording")
                    recording = true
                case .stopAndProcess, .cancel:
                    #expect(recording, "\(action) without a recording")
                    recording = false
                case .enteredHandsFree:
                    #expect(recording)
                case .scheduleTimer:
                    break
                }
            }
            #expect(gesture.isRecording == recording)
            if gesture.isHandsFree {
                #expect(gesture.isRecording)
            }
        }
    }

    /// Real key presses with timers delivered as a controller would (each once, in order, at its
    /// deadline): a timer only ends a tap's window once that window is over, and no recording
    /// is left running after the key is released and every timer has fired.
    @Test("Timers never end a window early or leave a recording running", arguments: 0..<20)
    func timersBehaveWithRealisticDelivery(seed: UInt64) {
        let windowMs = 300
        var random = SplitMix64(seed: seed)
        var gesture = Self.gesture(handsFree: true)
        var timerDeadlines: [Int] = []
        var lastTapReleasedAt = 0
        var keyDown = false
        var now = 0

        func deliverTimers(until time: Int) {
            while let deadline = timerDeadlines.first, deadline <= time {
                timerDeadlines.removeFirst()
                if gesture.handle(.timerFired, atMs: deadline) == [.cancel] {
                    #expect(deadline - lastTapReleasedAt >= windowMs, "a stale timer cut a window short")
                }
            }
        }

        for _ in 0..<300 {
            now += Int(random.next() % 400)
            deliverTimers(until: now)
            let roll = random.next() % 10
            let input: HotkeyInput = switch roll {
            case 0: .escape
            case 1 where keyDown: .otherKey
            default: keyDown ? .released : .pressed
            }
            if input == .pressed || input == .released { keyDown.toggle() }
            for action in gesture.handle(input, atMs: now) {
                if case .scheduleTimer(let ms) = action {
                    timerDeadlines.append(now + ms)
                    lastTapReleasedAt = now
                }
            }
        }
        if keyDown {
            now += 1
            for action in gesture.handle(.released, atMs: now) {
                if case .scheduleTimer(let ms) = action {
                    timerDeadlines.append(now + ms)
                    lastTapReleasedAt = now
                }
            }
        }
        deliverTimers(until: .max)
        #expect(!gesture.isRecording || gesture.isHandsFree)
    }

    private static func gesture(handsFree: Bool) -> HotkeyGesture {
        HotkeyGesture(configuration: HotkeyGestureConfiguration(tapMaxMs: 300, doubleTapWindowMs: 300, handsFreeEnabled: handsFree))
    }
}

@Suite("HotkeyEvent to gesture input")
struct HotkeyEventInputTests {
    @Test("Monitor events map to gesture inputs", arguments: [
        (HotkeyEvent.pressed, HotkeyInput?.some(.pressed)),
        (.released, .released),
        (.escape, .escape),
        (.otherKey, .otherKey),
        (.undo, nil),
    ])
    func eventsMapToInputs(event: HotkeyEvent, expected: HotkeyInput?) {
        #expect(event.gestureInput == expected)
    }
}

/// A small deterministic generator, so the randomised test is reproducible from its seed.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
