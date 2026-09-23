import AppKit
import Dictation
import Hotkey

/// Delivers this app's key presses and modifier changes to a shortcut recorder, as
/// ``KeyEventInfo`` values. A thin adapter: every decision is ``HotkeyRecorderModel``'s.
///
/// Uses a local monitor, so it only sees events meant for this app's windows, and of those only
/// the recorder's own window. It stops itself when that window stops being key or closes, and
/// says so through `onInterrupted`: a closed or hidden Settings window does not always make its
/// SwiftUI views disappear, and a monitor left installed would keep swallowing typing.
/// The owner still calls ``stop()`` when recording ends and when its view disappears.
///
/// While it runs it holds a ``HotkeySuspension``, so the app's global shortcuts are paused and
/// every key reaches the recorder: pressing fn to record it must not start a dictation, and the
/// current shortcuts must not be swallowed before the recorder sees them. Every way of stopping
/// ends the suspension, and one dropped with the monitor ends itself.
@MainActor
final class HotkeyRecorderEventMonitor {
    private var token: Any?
    /// Pauses the global shortcuts while recording; ended by ``stop()``.
    private var suspension: HotkeySuspension?
    private var windowObservers: [any NSObjectProtocol] = []
    private var notificationCenter: NotificationCenter?
    /// The recorder's window; events for other windows pass through untouched.
    private weak var window: AnyObject?
    private var handler: (@MainActor (KeyEventInfo) -> Bool)?
    private var onInterrupted: (@MainActor () -> Void)?

    var isRunning: Bool { token != nil }

    /// Starts delivering events to `handler`, replacing any earlier handler.
    ///
    /// - Parameters:
    ///   - window: The recorder's window (normally `NSApp.keyWindow` when recording starts).
    ///     `nil` delivers every window's events and relies on the owner to stop.
    ///   - notificationCenter: Where the window posts resign-key and close; tests pass their own.
    ///   - suspension: The pause of the global shortcuts for this recording; the monitor ends it
    ///     when it stops, however that happens.
    ///   - handler: Returns whether to swallow the event, so it never reaches the window.
    ///   - onInterrupted: Called once if the window stops being key or closes; the monitor has
    ///     already stopped by then.
    func start(
        window: AnyObject?,
        notificationCenter: NotificationCenter = .default,
        suspension: HotkeySuspension,
        handler: @escaping @MainActor (KeyEventInfo) -> Bool,
        onInterrupted: @escaping @MainActor () -> Void
    ) {
        stop()
        self.suspension = suspension
        self.window = window
        self.handler = handler
        self.onInterrupted = onInterrupted
        // Local monitors run on the main thread, in the app's event loop, so the closure keeps
        // this main-actor context.
        token = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, let handler = self.handler, self.isForRecorderWindow(event),
                  let info = Self.keyEventInfo(from: event)
            else { return event }
            return handler(info) ? nil : event
        }
        guard let window else { return }
        self.notificationCenter = notificationCenter
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            let observer = notificationCenter.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.interrupt() }
            }
            windowObservers.append(observer)
        }
    }

    /// Removes the monitor and the window observers, and resumes the global shortcuts. Safe to
    /// call when it is not running.
    func stop() {
        if let token {
            NSEvent.removeMonitor(token)
            self.token = nil
        }
        suspension?.end()
        suspension = nil
        for observer in windowObservers {
            notificationCenter?.removeObserver(observer)
        }
        windowObservers = []
        notificationCenter = nil
        window = nil
        handler = nil
        onInterrupted = nil
    }

    private func interrupt() {
        guard isRunning else { return }
        let onInterrupted = onInterrupted
        stop()
        onInterrupted?()
    }

    private func isForRecorderWindow(_ event: NSEvent) -> Bool {
        guard let window else { return true }
        return event.window == nil || event.window === window
    }

    /// The recorder's view of an AppKit key event; `nil` for other event types.
    ///
    /// `modifierFlags` carries the same bits as `CGEventFlags`, device-dependent left/right bits
    /// included, so it converts directly to ``KeyEventFlags``.
    static func keyEventInfo(from event: NSEvent) -> KeyEventInfo? {
        let type: KeyEventType
        switch event.type {
        case .keyDown: type = .keyDown
        case .keyUp: type = .keyUp
        case .flagsChanged: type = .flagsChanged
        default: return nil
        }
        return KeyEventInfo(
            type: type,
            keyCode: event.keyCode,
            flags: KeyEventFlags(rawValue: UInt64(event.modifierFlags.rawValue)),
            // `isARepeat` raises for anything but key-down and key-up events.
            isAutorepeat: type == .flagsChanged ? false : event.isARepeat
        )
    }
}
