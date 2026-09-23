import AppKit
import Dictation
@testable import DictationUI
import Foundation
import Hotkey
import Testing

@Suite("HotkeyRecorderEventMonitor")
@MainActor
struct HotkeyRecorderEventMonitorTests {
    /// Stands in for the recorder's window: the monitor only compares it and observes it.
    private let window = NSObject()
    private let center = NotificationCenter()

    private func startedMonitor(interruptions: Counter, resumes: Counter = Counter()) -> HotkeyRecorderEventMonitor {
        let monitor = HotkeyRecorderEventMonitor()
        start(monitor, interruptions: interruptions, resumes: resumes)
        return monitor
    }

    /// Starts `monitor` holding a suspension that counts its end in `resumes`.
    private func start(_ monitor: HotkeyRecorderEventMonitor, interruptions: Counter, resumes: Counter) {
        let suspension = HotkeySuspension { resumes.count += 1 }
        monitor.start(window: window, notificationCenter: center, suspension: suspension, handler: { _ in false }) {
            interruptions.count += 1
        }
    }

    // MARK: - Stopping with the window

    @Test(arguments: [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification])
    func stopsWhenItsWindowResignsKeyOrCloses(_ name: Notification.Name) {
        let interruptions = Counter()
        let monitor = startedMonitor(interruptions: interruptions)
        #expect(monitor.isRunning)

        center.post(name: name, object: window)
        #expect(!monitor.isRunning)
        #expect(interruptions.count == 1)

        // Its observers went with it.
        center.post(name: name, object: window)
        #expect(interruptions.count == 1)
    }

    @Test func anotherWindowDoesNotStopIt() {
        let interruptions = Counter()
        let monitor = startedMonitor(interruptions: interruptions)
        center.post(name: NSWindow.didResignKeyNotification, object: NSObject())
        #expect(monitor.isRunning)
        #expect(interruptions.count == 0)
        monitor.stop()
    }

    @Test func stoppingByTheOwnerIsNotAnInterruption() {
        let interruptions = Counter()
        let monitor = startedMonitor(interruptions: interruptions)
        monitor.stop()
        #expect(!monitor.isRunning)
        center.post(name: NSWindow.willCloseNotification, object: window)
        #expect(interruptions.count == 0)
    }

    // MARK: - Pausing the global shortcuts

    @Test func theShortcutsStayPausedWhileItRunsAndResumeWhenTheOwnerStopsIt() {
        let resumes = Counter()
        let monitor = startedMonitor(interruptions: Counter(), resumes: resumes)
        #expect(resumes.count == 0)
        monitor.stop()
        #expect(resumes.count == 1)
        monitor.stop()
        #expect(resumes.count == 1, "stopping again resumes nothing more")
    }

    @Test(arguments: [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification])
    func theShortcutsResumeWhenItsWindowResignsKeyOrCloses(_ name: Notification.Name) {
        let resumes = Counter()
        let monitor = startedMonitor(interruptions: Counter(), resumes: resumes)
        center.post(name: name, object: window)
        #expect(resumes.count == 1)
        withExtendedLifetime(monitor) {}
    }

    @Test func restartingEndsTheEarlierPauseOnly() {
        let first = Counter(), second = Counter()
        let monitor = startedMonitor(interruptions: Counter(), resumes: first)
        start(monitor, interruptions: Counter(), resumes: second)
        #expect(first.count == 1)
        #expect(second.count == 0)
        monitor.stop()
        #expect(second.count == 1)
    }

    @Test func aMonitorDroppedWhileRunningStillResumesTheShortcuts() async throws {
        let resumes = Counter()
        do {
            _ = startedMonitor(interruptions: Counter(), resumes: resumes)
        }
        for _ in 0..<100 where resumes.count == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(resumes.count == 1)
    }

    // MARK: - Converting events

    @Test func aKeyDownKeepsItsCodeRepeatAndLeftRightBits() throws {
        // ⌃⌥ held with the right ⌥ key: device-independent and device-dependent bits together.
        let raw = NSEvent.ModifierFlags([.control, .option]).rawValue
            | UInt(KeyEventFlags.leftControl.rawValue) | UInt(KeyEventFlags.rightOption.rawValue)
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: raw),
            timestamp: 0, windowNumber: 0, context: nil, characters: " ", charactersIgnoringModifiers: " ",
            isARepeat: true, keyCode: 49
        ))
        let info = try #require(HotkeyRecorderEventMonitor.keyEventInfo(from: event))
        #expect(info.type == .keyDown)
        #expect(info.keyCode == 49)
        #expect(info.isAutorepeat)
        #expect(info.flags.contains([.control, .option, .leftControl, .rightOption]))
        #expect(!info.flags.contains(.leftOption))
    }

    @Test func aModifierChangeIsNeverARepeat() throws {
        let event = try #require(NSEvent.keyEvent(
            with: .flagsChanged, location: .zero, modifierFlags: .function,
            timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: ModifierKey.fn.keyCode
        ))
        let info = try #require(HotkeyRecorderEventMonitor.keyEventInfo(from: event))
        #expect(info == KeyEventInfo(type: .flagsChanged, keyCode: 63, flags: .secondaryFn, isAutorepeat: false))
    }
}

/// Counts calls from a closure handed to the monitor.
@MainActor
private final class Counter {
    var count = 0
}
