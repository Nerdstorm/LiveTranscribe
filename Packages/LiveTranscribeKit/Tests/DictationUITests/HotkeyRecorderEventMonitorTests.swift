import AppKit
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

    private func startedMonitor(interruptions: Counter) -> HotkeyRecorderEventMonitor {
        let monitor = HotkeyRecorderEventMonitor()
        monitor.start(window: window, notificationCenter: center, handler: { _ in false }) {
            interruptions.count += 1
        }
        return monitor
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
