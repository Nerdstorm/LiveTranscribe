import CoreGraphics
import Foundation
import Hotkey
import Insertion
import Observation
import Permissions
import Persistence
import Shared

/// System-wide dictation: turns hotkey gestures into recordings, and recordings into text at the
/// cursor. Owns the flow and its state for the HUD and the menu; every step it drives lives in
/// its own slice and is injected.
///
/// Steps run one at a time in the order the gestures arrive, so a release is never handled
/// before the press that started the recording.
@MainActor
@Observable
public final class DictationController {
    public enum Phase: Sendable, Equatable {
        case idle
        case recording(handsFree: Bool)
        case processing
    }

    /// What was last inserted, for *Undo AI edit*.
    struct UndoEntry {
        let record: InsertionRecord
        /// The dictation without cleanup, spaced like the inserted text.
        let uncleaned: String
    }

    public private(set) var phase: Phase = .idle
    /// Whether the dictation shortcut works, for the menu and Settings. It keeps its value while
    /// the shortcuts are suspended (see ``hotkeysSuspended``): a pause lasts only while a shortcut
    /// is recorded, and the shortcut works again as soon as it ends.
    public internal(set) var hotkeyState: HotkeyState = .stopped
    /// Whether the shortcuts are paused by ``suspendHotkeys()``. No dictation runs meanwhile.
    public var hotkeysSuspended: Bool { !activeSuspensions.isEmpty }
    /// The latest message for the HUD; cleared after the notice time in Settings.
    public private(set) var notice: DictationNotice?
    /// Microphone level while recording, 0...1.
    public private(set) var inputLevel: Float = 0
    /// The caret in the field the HUD is about (the one being dictated into, or undone in), for
    /// placing it. `nil` when unknown or when no field is concerned: from the start of each
    /// attempt until its field has been read, and for a notice between dictations.
    public private(set) var caretRect: CGRect?
    /// The last dictated text, for the menu's *Copy Last Dictation*.
    public private(set) var lastText: String?

    let dependencies: Dependencies
    @ObservationIgnored var gesture: HotkeyGesture
    /// Bumped whenever ``gesture`` is replaced, so a timer the old gesture asked for is dropped
    /// instead of reaching the new one.
    @ObservationIgnored var gestureGeneration = 0
    /// Timing from Settings that changed mid-gesture; applied once the gesture is idle.
    @ObservationIgnored var pendingGestureConfiguration: HotkeyGestureConfiguration?
    @ObservationIgnored var runningBindings: HotkeyBindings?
    /// Between ``start()`` and ``stop()``. While stopped, neither a settings change nor the end
    /// of a suspension starts the hotkey monitor or keeps the microphone ready.
    @ObservationIgnored var isStarted = false
    /// The suspensions that have not ended yet, by identifier; see ``suspendHotkeys()``.
    var activeSuspensions: Set<Int> = []
    @ObservationIgnored var lastSuspensionID = 0
    /// The recording was started from the menu, not the hotkey, so the gesture knows nothing of it.
    @ObservationIgnored var startedFromMenu = false
    @ObservationIgnored private var started: ContinuousClock.Instant
    @ObservationIgnored private var operations: Task<Void, Never>?
    @ObservationIgnored var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var permissionTask: Task<Void, Never>?
    @ObservationIgnored private var levelTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored var processingTask: Task<DictationProcessor.Output, Error>?
    @ObservationIgnored var cancelRequested = false
    @ObservationIgnored var undoEntry: UndoEntry?

    public init(dependencies: Dependencies) {
        self.dependencies = dependencies
        let settings = dependencies.settings().dictation
        gesture = HotkeyGesture(configuration: Self.gestureConfiguration(settings))
        started = dependencies.now()
    }

    // MARK: - Lifecycle

    /// Starts listening for the hotkey, and again whenever Accessibility is granted.
    public func start() {
        isStarted = true
        applySettings()
        guard permissionTask == nil else { return }
        let changes = dependencies.accessibility.changes()
        permissionTask = Task { [weak self] in
            for await granted in changes {
                guard let self else { return }
                if granted, self.hotkeyState == .needsAccessibility {
                    Log.dictation.info("Accessibility granted; starting the dictation hotkey")
                    self.applySettings()
                } else if !granted, case .running = self.hotkeyState {
                    Log.dictation.notice("Accessibility was revoked; the dictation hotkey stops")
                    self.stopHotkeys()
                    self.hotkeyState = .needsAccessibility
                }
            }
        }
        let levels = dependencies.recorder.levels
        levelTask = Task { [weak self] in
            for await level in levels {
                guard let self else { return }
                if case .recording = self.phase { self.inputLevel = level }
            }
        }
    }

    /// Applies changed settings: the hotkeys and gestures, and whether the microphone stays ready.
    ///
    /// The hotkey monitor restarts only when its bindings changed (or it is not running), so a
    /// change elsewhere in Settings never interrupts a dictation. While the shortcuts are
    /// suspended it stays stopped, and starts with the settings current when they resume. After
    /// ``stop()`` nothing starts until ``start()``.
    public func applySettings() {
        let settings = dependencies.settings()
        startHotkeys(settings.dictation)
        let recorder = dependencies.recorder
        let permission = dependencies.microphonePermission
        let keepReady = isStarted && settings.dictation.enabled && settings.dictation.keepMicrophoneReady
        let configuration = DictationRecorder.Configuration(
            preRollMs: settings.dictation.preRollMs,
            maxDurationSeconds: settings.dictation.maxRecordingSeconds
        )
        enqueue {
            await recorder.update(configuration)
            do {
                try await recorder.setKeepReady(keepReady && permission.status() == .granted)
            } catch {
                Log.dictation.error("Could not keep the microphone ready: \(error.localizedDescription, privacy: .public)")
            }
        }
        pruneHistory(retentionDays: settings.dictation.historyRetentionDays)
    }

    /// Stops the hotkey and releases the microphone.
    public func stop() {
        isStarted = false
        stopHotkeys()
        permissionTask?.cancel()
        permissionTask = nil
        levelTask?.cancel()
        levelTask = nil
        hotkeyState = .stopped
        let recorder = dependencies.recorder
        enqueue {
            try? await recorder.setKeepReady(false)
            await recorder.cancel()
        }
    }

    // MARK: - Gesture steps

    /// Marks the recording hands-free after a double tap; see ``handle(_:)``.
    func enterHandsFree() {
        if case .recording = phase { phase = .recording(handsFree: true) }
    }

    // MARK: - Menu and HUD intents

    /// Starts a hands-free dictation, or stops the current one: for the menu, without the hotkey.
    public func toggleDictation() {
        switch phase {
        case .idle:
            guard !hotkeysSuspended else {
                // A shortcut is being recorded in Settings; a dictation now would type into it.
                setCaret(nil)
                return show(.recordingShortcut)
            }
            gesture.reset()
            startedFromMenu = true
            enqueue { await self.beginRecording(handsFree: true) }
        case .recording:
            gesture.reset()
            enqueue { await self.finishRecording() }
        case .processing:
            break
        }
    }

    /// Cancels whatever is in progress.
    public func cancel() {
        switch phase {
        case .idle: break
        case .recording:
            gesture.reset()
            enqueue { await self.discardRecording(notice: .cancelled) }
        case .processing:
            cancelProcessing()
        }
    }

    public func undoLastEdit() {
        enqueue { await self.performUndo() }
    }

    /// Shows a microphone change reported by capture, such as a fallback to the system default.
    /// Between dictations it concerns no field, so it is not placed at the last one's caret.
    public func showMicrophoneNotice(_ message: String) {
        if phase == .idle { setCaret(nil) }
        show(.microphone(message))
    }

    public func dismissNotice() {
        noticeTask?.cancel()
        notice = nil
    }

    // MARK: - Helpers

    func enqueue(_ operation: @escaping @MainActor () async -> Void) {
        let previous = operations
        operations = Task {
            await previous?.value
            await operation()
        }
    }

    /// Waits until every queued step has run; for tests.
    func settle() async {
        while let current = operations {
            await current.value
            if operations == current { return }
        }
    }

    func show(_ notice: DictationNotice?) {
        noticeTask?.cancel()
        self.notice = notice
        guard notice != nil else { return }
        let seconds = dependencies.settings().dictation.noticeSeconds
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    func setPhase(_ newPhase: Phase) {
        phase = newPhase
        dependencies.hotkeys.setCapturingEscape(newPhase != .idle)
        if newPhase == .idle {
            inputLevel = 0
            startedFromMenu = false
        }
    }

    func setCaret(_ rect: CGRect?) { caretRect = rect }
    func setLastText(_ text: String) { lastText = text }

    func elapsedMs() -> Int {
        started.duration(to: dependencies.now()).wholeMilliseconds
    }

    /// The focused field, read off the main actor: Accessibility calls wait on the other app.
    func currentTarget() async -> InsertionTarget {
        let focus = dependencies.focus
        return await Task.detached { focus.currentTarget() }.value
    }

    private func pruneHistory(retentionDays: Int) {
        guard let cutoff = HistoryRetention.cutoff(now: Date(), retentionDays: retentionDays) else { return }
        let history = dependencies.history
        Task {
            do {
                let removed = try await history.prune(olderThan: cutoff)
                if removed > 0 { Log.dictation.info("Pruned \(removed) dictations older than \(retentionDays) days") }
            } catch {
                Log.dictation.error("Pruning the dictation history failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
