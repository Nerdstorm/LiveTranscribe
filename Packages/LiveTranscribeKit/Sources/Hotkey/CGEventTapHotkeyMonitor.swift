import Foundation
import Shared

/// A keyboard tap feeding one ``HotkeyEventRouter``, as the monitor sees it.
///
/// A protocol so the monitor's start, stop and restart rules are tested with a fake: a real tap
/// needs Accessibility access and real key presses.
protocol KeyEventTap: AnyObject {
    /// Detaches the tap, so no more events reach its router. Called exactly once.
    func tearDown()
}

/// Watches the keyboard system-wide through an active Core Graphics event tap.
///
/// An active tap (rather than a listen-only one) is needed so a key-combination hotkey and Esc
/// can be swallowed instead of also reaching the frontmost app. Creating it requires
/// Accessibility access; without it ``start(binding:undoBinding:)`` throws
/// ``HotkeyError/permissionDenied``.
///
/// This class owns the lifecycle: one run at a time, the stream finished on stop, and the tap
/// stopped when the consumer stops listening, so keys are never swallowed for nobody. The tap
/// itself is ``CGKeyEventTap``, and every decision about a key is ``HotkeyMatcher``'s. Nothing is
/// logged per key, for privacy and speed; only start, stop and failures are.
///
/// `@unchecked Sendable`: the mutable state (`running`, `capturingEscape`) is read and written
/// only while holding `lock`. The tap it holds is not `Sendable`, which is why a checked lock
/// type cannot be used; it is only created and torn down, each once, never shared otherwise.
public final class CGEventTapHotkeyMonitor: HotkeyMonitor, @unchecked Sendable {
    /// Creates and attaches a tap that feeds the given router.
    typealias TapFactory = @Sendable (HotkeyEventRouter) throws -> any KeyEventTap

    private struct Run {
        let tap: any KeyEventTap
        let router: HotkeyEventRouter
    }

    private let lock = NSLock()
    private let makeTap: TapFactory
    private var running: Run?
    /// Kept across runs, so a restart for a new binding keeps capturing Esc mid-dictation.
    private var capturingEscape = false

    public convenience init() {
        self.init(makeTap: { try CGKeyEventTap(router: $0) })
    }

    /// For tests: `makeTap` stands in for the Core Graphics tap.
    init(makeTap: @escaping TapFactory) {
        self.makeTap = makeTap
    }

    deinit {
        // No other reference exists any more, so the lock is not needed.
        if let running {
            running.tap.tearDown()
            running.router.finish()
        }
    }

    public func start(binding: HotkeyBinding, undoBinding: HotkeyBinding?) throws -> AsyncStream<HotkeyEvent> {
        do {
            try binding.validate()
        } catch {
            Log.hotkey.error("Hotkey monitor refused an invalid shortcut: \(error.localizedDescription, privacy: .public)")
            throw HotkeyError.invalidBinding(error)
        }
        let usableUndo = HotkeyMatcher.effectiveUndoBinding(undoBinding, dictation: binding)
        if undoBinding != nil, usableUndo == nil {
            Log.hotkey.notice("The undo shortcut is a modifier on its own, invalid, or the dictation shortcut; undo is off")
        }

        return try lock.withLock {
            guard running == nil else { throw HotkeyError.alreadyRunning }
            let (stream, continuation) = AsyncStream.makeStream(of: HotkeyEvent.self, bufferingPolicy: .unbounded)
            let router = HotkeyEventRouter(
                binding: binding,
                undoBinding: usableUndo,
                capturingEscape: capturingEscape,
                continuation: continuation
            )
            let tap: any KeyEventTap
            do {
                tap = try makeTap(router)
            } catch {
                continuation.finish()
                Log.hotkey.error("Hotkey monitor could not start: \(error.localizedDescription, privacy: .public)")
                throw error
            }
            running = Run(tap: tap, router: router)
            // A consumer that stops listening (its task cancelled, or the stream dropped) must
            // not leave keys being swallowed for nobody. Runs after `start` has returned, so it
            // never meets `lock` held.
            continuation.onTermination = { [weak self, weak router] termination in
                guard case .cancelled = termination, let self, let router else { return }
                self.stop { $0.router === router }
            }
            Log.hotkey.info("Hotkey monitor started: \(binding.displayName, privacy: .public)")
            return stream
        }
    }

    public func stop() {
        stop { _ in true }
    }

    public func setCapturingEscape(_ capturing: Bool) {
        lock.withLock {
            capturingEscape = capturing
            running?.router.setCapturingEscape(capturing)
        }
    }

    /// Stops the current run if `shouldStop` accepts it. The tap is torn down and the stream
    /// finished outside the lock, because finishing runs the stream's termination handler.
    private func stop(where shouldStop: (Run) -> Bool) {
        let stopped: Run? = lock.withLock {
            guard let running, shouldStop(running) else { return nil }
            self.running = nil
            return running
        }
        guard let stopped else { return }
        stopped.tap.tearDown()
        stopped.router.finish()
        Log.hotkey.info("Hotkey monitor stopped")
    }
}
