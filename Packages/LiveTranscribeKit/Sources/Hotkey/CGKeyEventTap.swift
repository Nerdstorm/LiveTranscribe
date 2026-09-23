import CoreGraphics
import Foundation
import Shared

/// An active Core Graphics keyboard tap on its own thread's run loop, for one run of
/// ``CGEventTapHotkeyMonitor``.
///
/// The tap has its own thread so a busy main thread never delays key handling: macOS disables
/// a tap whose callback is slow, which would drop a hotkey release mid-dictation. The callback
/// only converts the event and asks ``HotkeyEventRouter``; it cannot be unit-tested, so it is
/// kept this thin.
final class CGKeyEventTap: KeyEventTap {
    private let tap: CFMachPort
    private let source: CFRunLoopSource
    private let runLoop: CFRunLoop

    /// Creates the tap and starts its thread. Returns once the tap is receiving events.
    init(router: HotkeyEventRouter) throws {
        let context = TapContext(router: router)
        let events: [CGEventType] = [.flagsChanged, .keyDown, .keyUp]
        let mask = events.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: hotkeyTapCallback,
            // Unretained: the tap thread keeps `context` alive until its run loop has exited,
            // after which the callback can no longer run.
            userInfo: Unmanaged.passUnretained(context).toOpaque()
        ) else {
            throw HotkeyError.permissionDenied
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            throw HotkeyError.startFailed("the event tap has no run loop source")
        }
        context.tap = tap

        let handoff = RunLoopHandoff()
        let thread = Thread { [context, source = SendableRunLoopSource(source)] in
            let runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(runLoop, source.value, .commonModes)
            handoff.publish(runLoop)
            // Returns once `tearDown()` stops the run loop (or has removed the source, if it
            // ran before this line).
            CFRunLoopRun()
            withExtendedLifetime(context) {}
        }
        thread.name = "LiveTranscribe.HotkeyTap"
        // At least the main thread's QoS: key handling must never wait behind other work.
        thread.qualityOfService = .userInteractive
        thread.start()

        guard let runLoop = handoff.wait() else {
            CFMachPortInvalidate(tap)
            throw HotkeyError.startFailed("the event tap thread has no run loop")
        }
        self.tap = tap
        self.source = source
        self.runLoop = runLoop
    }

    func tearDown() {
        CGEvent.tapEnable(tap: tap, enable: false)
        CFRunLoopRemoveSource(runLoop, source, .commonModes)
        CFMachPortInvalidate(tap)
        CFRunLoopStop(runLoop)
        CFRunLoopWakeUp(runLoop)
    }
}

/// What the C callback reaches through `userInfo`.
///
/// `@unchecked Sendable`: `router` is thread-safe, and `tap` is assigned once before the tap
/// thread starts (starting a thread orders that write before everything the thread does) and
/// only read afterwards.
private final class TapContext: @unchecked Sendable {
    let router: HotkeyEventRouter
    var tap: CFMachPort?

    init(router: HotkeyEventRouter) {
        self.router = router
    }

    /// macOS disables a tap whose callback took too long, or on some user input; key events
    /// are lost until it is enabled again, possibly including the hotkey's release.
    func reenable(after type: CGEventType) {
        guard let tap else { return }
        let reason = type == .tapDisabledByTimeout ? "timeout" : "user input"
        CGEvent.tapEnable(tap: tap, enable: true)
        guard CGEvent.tapIsEnabled(tap: tap) else {
            Log.hotkey.error("Hotkey event tap was disabled (\(reason, privacy: .public)) and could not be re-enabled")
            return
        }
        Log.hotkey.notice("Hotkey event tap was disabled (\(reason, privacy: .public)); re-enabled")
        let flags = KeyEventFlags(rawValue: CGEventSource.flagsState(.combinedSessionState).rawValue)
        router.resynchronize(
            isKeyDown: { CGEventSource.keyState(.combinedSessionState, key: $0) },
            modifierFlags: flags
        )
    }
}

/// Hands the tap thread's run loop to the thread that started it.
///
/// `@unchecked Sendable`: `runLoop` is written once on the tap thread before `ready` is
/// signalled and read only after waiting on it; the semaphore orders the two.
private final class RunLoopHandoff: @unchecked Sendable {
    private let ready = DispatchSemaphore(value: 0)
    private var runLoop: CFRunLoop?

    func publish(_ runLoop: CFRunLoop?) {
        self.runLoop = runLoop
        ready.signal()
    }

    func wait() -> CFRunLoop? {
        ready.wait()
        return runLoop
    }
}

/// Carries the tap's run loop source to its thread.
///
/// `@unchecked Sendable`: `CFRunLoopSource` is not marked `Sendable` in the SDK, but Core
/// Foundation run loop sources may be added to and removed from run loops on any thread; the
/// source is only handed over here, never mutated.
private struct SendableRunLoopSource: @unchecked Sendable {
    let value: CFRunLoopSource

    init(_ value: CFRunLoopSource) {
        self.value = value
    }
}

/// The event tap callback. Returning `nil` swallows the event.
///
/// Wrapped in an autorelease pool: nothing drains one on a secondary thread's run loop, so any
/// object a system call autoreleases here would otherwise pile up for as long as the app runs.
private func hotkeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let context = Unmanaged<TapContext>.fromOpaque(userInfo).takeUnretainedValue()
    let swallow: Bool = autoreleasepool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            context.reenable(after: type)
            return false
        default:
            guard let info = KeyEventInfo(event: event, type: type) else { return false }
            return context.router.route(info)
        }
    }
    return swallow ? nil : Unmanaged.passUnretained(event)
}
