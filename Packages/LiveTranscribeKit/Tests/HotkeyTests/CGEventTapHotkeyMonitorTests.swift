import Foundation
@testable import Hotkey
import os
import Testing

/// Stands in for the Core Graphics tap, which needs Accessibility access and real key presses:
/// records the router each tap was given and every tear-down.
final class FakeTaps: Sendable {
    private struct State: Sendable {
        var routers: [HotkeyEventRouter] = []
        var tearDowns = 0
        var nextFailure: HotkeyError?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var routers: [HotkeyEventRouter] { state.withLock { $0.routers } }
    var tearDowns: Int { state.withLock { $0.tearDowns } }

    /// Makes the next tap fail to start, as a missing Accessibility grant would.
    func failNext(with error: HotkeyError) {
        state.withLock { $0.nextFailure = error }
    }

    func make(router: HotkeyEventRouter) throws -> any KeyEventTap {
        let failure: HotkeyError? = state.withLock { state in
            defer { state.nextFailure = nil }
            if state.nextFailure == nil {
                state.routers.append(router)
            }
            return state.nextFailure
        }
        if let failure { throw failure }
        return FakeTap(taps: self)
    }

    fileprivate func recordTearDown() {
        state.withLock { $0.tearDowns += 1 }
    }
}

private final class FakeTap: KeyEventTap {
    private let taps: FakeTaps

    init(taps: FakeTaps) {
        self.taps = taps
    }

    func tearDown() {
        taps.recordTearDown()
    }
}

@Suite("CGEventTapHotkeyMonitor lifecycle")
struct CGEventTapHotkeyMonitorTests {
    private static func monitor() -> (CGEventTapHotkeyMonitor, FakeTaps) {
        let taps = FakeTaps()
        return (CGEventTapHotkeyMonitor(makeTap: { try taps.make(router: $0) }), taps)
    }

    private static func collect(_ stream: AsyncStream<HotkeyEvent>) async -> [HotkeyEvent] {
        var events: [HotkeyEvent] = []
        for await event in stream {
            events.append(event)
        }
        return events
    }

    @Test func deliversTheTapsEventsUntilStopped() async throws {
        let (monitor, taps) = Self.monitor()
        let stream = try monitor.start(binding: .defaultDictation, undoBinding: .defaultUndo)
        let router = try #require(taps.routers.first)
        #expect(!router.route(Keys.flagsChanged(63, [.secondaryFn])))
        #expect(router.route(Keys.down(Keys.keyZ, [.control, .option])))
        monitor.stop()
        #expect(taps.tearDowns == 1)
        #expect(await Self.collect(stream) == [.pressed, .otherKey, .undo])
        monitor.stop()
        #expect(taps.tearDowns == 1, "a second stop does nothing")
    }

    @Test func startingTwiceThrowsUntilStopped() throws {
        let (monitor, taps) = Self.monitor()
        let first = try monitor.start(binding: .defaultDictation, undoBinding: nil)
        try withExtendedLifetime(first) {
            #expect(throws: HotkeyError.alreadyRunning) {
                try monitor.start(binding: .defaultDictation, undoBinding: nil)
            }
            #expect(taps.routers.count == 1)
            monitor.stop()
            let second = try monitor.start(binding: Keys.controlOption, undoBinding: nil)
            withExtendedLifetime(second) {
                #expect(taps.routers.count == 2)
                monitor.stop()
            }
        }
        #expect(taps.tearDowns == 2)
    }

    @Test("An invalid combination is refused before any tap is created", arguments: [
        (HotkeyBinding.keyCombo(keyCode: Keys.keyA, modifiers: []), HotkeyBindingError.needsCommandOptionOrControl),
        (.keyCombo(keyCode: Keys.keyA, modifiers: [.shift]), .needsCommandOptionOrControl),
        (.keyCombo(keyCode: 56, modifiers: [.command]), .modifierAsMainKey),
    ])
    func invalidBindingIsRefused(binding: HotkeyBinding, reason: HotkeyBindingError) {
        let (monitor, taps) = Self.monitor()
        #expect(throws: HotkeyError.invalidBinding(reason)) {
            try monitor.start(binding: binding, undoBinding: nil)
        }
        #expect(taps.routers.isEmpty)
    }

    @Test func anUnusableUndoBindingIsDroppedSoPlainKeysPassThrough() throws {
        let (monitor, taps) = Self.monitor()
        let stream = try monitor.start(binding: .defaultDictation, undoBinding: .keyCombo(keyCode: Keys.keyZ, modifiers: []))
        try withExtendedLifetime(stream) {
            let router = try #require(taps.routers.first)
            #expect(!router.route(Keys.down(Keys.keyZ)))
            #expect(!router.route(Keys.up(Keys.keyZ)))
            monitor.stop()
        }
    }

    @Test func aTapThatCannotStartIsReportedAndLeavesTheMonitorStopped() async throws {
        let (monitor, taps) = Self.monitor()
        taps.failNext(with: .permissionDenied)
        #expect(throws: HotkeyError.permissionDenied) {
            try monitor.start(binding: .defaultDictation, undoBinding: nil)
        }
        #expect(taps.tearDowns == 0)
        let stream = try monitor.start(binding: .defaultDictation, undoBinding: nil)
        monitor.stop()
        #expect(await Self.collect(stream).isEmpty)
    }

    @Test func escapeCaptureAppliesAtOnceAndAcrossRestarts() throws {
        let (monitor, taps) = Self.monitor()
        monitor.setCapturingEscape(true)
        let first = try monitor.start(binding: .defaultDictation, undoBinding: nil)
        try withExtendedLifetime(first) {
            let router = try #require(taps.routers.last)
            #expect(router.route(Keys.down(Keys.escape)))
            #expect(router.route(Keys.up(Keys.escape)))
            monitor.setCapturingEscape(false)
            #expect(!router.route(Keys.down(Keys.escape)))
            #expect(!router.route(Keys.up(Keys.escape)))
            monitor.setCapturingEscape(true)
            monitor.stop()
        }
        let second = try monitor.start(binding: .defaultDictation, undoBinding: nil)
        try withExtendedLifetime(second) {
            let router = try #require(taps.routers.last)
            #expect(router.route(Keys.down(Keys.escape)), "a restart mid-dictation keeps capturing Esc")
            monitor.stop()
        }
    }

    @Test func cancellingTheConsumerStopsTheTap() async throws {
        let (monitor, taps) = Self.monitor()
        let stream = try monitor.start(binding: .defaultDictation, undoBinding: nil)
        let consumer = Task { await Self.collect(stream) }
        consumer.cancel()
        _ = await consumer.value
        #expect(taps.tearDowns == 1)
        // The monitor is free to start again.
        let again = try monitor.start(binding: .defaultDictation, undoBinding: nil)
        withExtendedLifetime(again) { monitor.stop() }
    }

    @Test func droppingTheStreamStopsTheTap() throws {
        let (monitor, taps) = Self.monitor()
        do {
            let stream = try monitor.start(binding: .defaultDictation, undoBinding: nil)
            withExtendedLifetime(stream) {
                #expect(taps.tearDowns == 0)
            }
        }
        #expect(taps.tearDowns == 1)
    }

    @Test func releasingTheMonitorStopsItsTap() async throws {
        let taps = FakeTaps()
        var monitor: CGEventTapHotkeyMonitor? = CGEventTapHotkeyMonitor(makeTap: { try taps.make(router: $0) })
        let stream = try #require(monitor).start(binding: .defaultDictation, undoBinding: nil)
        monitor = nil
        #expect(taps.tearDowns == 1)
        #expect(await Self.collect(stream).isEmpty)
    }

    @Test func stopAndEscapeCaptureAreSafeBeforeStart() {
        let monitor = CGEventTapHotkeyMonitor()
        monitor.setCapturingEscape(true)
        monitor.stop()
        monitor.stop()
    }

    @Test func errorsAreReadable() {
        #expect(HotkeyError.permissionDenied.errorDescription?.contains("Accessibility") == true)
        #expect(HotkeyError.alreadyRunning.errorDescription?.isEmpty == false)
        #expect(HotkeyError.startFailed("detail").errorDescription?.contains("detail") == true)
        #expect(HotkeyError.invalidBinding(.needsCommandOptionOrControl).errorDescription?.contains("⌘ Command") == true)
    }
}
