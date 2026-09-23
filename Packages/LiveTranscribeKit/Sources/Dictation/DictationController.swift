import Capture
import CoreGraphics
import Foundation
import Hotkey
import Insertion
import Observation
import Permissions
import Persistence
import Shared
import Snippets
import Vocabulary

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

    public struct Dependencies: Sendable {
        public var hotkeys: any HotkeyMonitor
        public var recorder: DictationRecorder
        public var processor: DictationProcessor
        public var focus: any FocusedTargetProvider
        public var delivery: any TextDelivery
        public var history: any DictationHistory
        public var snippets: @Sendable () async -> [Snippet]
        public var vocabulary: @Sendable () async -> [VocabularyEntry]
        public var settings: @Sendable () -> AppSettings
        public var readiness: @Sendable () async -> DictationReadiness
        public var microphonePermission: any MicrophonePermissionProviding
        public var accessibility: any AccessibilityPermissionProviding
        public var now: @Sendable () -> ContinuousClock.Instant

        public init(
            hotkeys: any HotkeyMonitor,
            recorder: DictationRecorder,
            processor: DictationProcessor,
            focus: any FocusedTargetProvider,
            delivery: any TextDelivery,
            history: any DictationHistory,
            snippets: @escaping @Sendable () async -> [Snippet],
            vocabulary: @escaping @Sendable () async -> [VocabularyEntry],
            settings: @escaping @Sendable () -> AppSettings,
            readiness: @escaping @Sendable () async -> DictationReadiness,
            microphonePermission: any MicrophonePermissionProviding,
            accessibility: any AccessibilityPermissionProviding,
            now: @escaping @Sendable () -> ContinuousClock.Instant
        ) {
            self.hotkeys = hotkeys
            self.recorder = recorder
            self.processor = processor
            self.focus = focus
            self.delivery = delivery
            self.history = history
            self.snippets = snippets
            self.vocabulary = vocabulary
            self.settings = settings
            self.readiness = readiness
            self.microphonePermission = microphonePermission
            self.accessibility = accessibility
            self.now = now
        }
    }

    /// What was last inserted, for *Undo AI edit*.
    struct UndoEntry {
        let record: InsertionRecord
        /// The dictation without cleanup, spaced like the inserted text.
        let uncleaned: String
    }

    /// The hotkey settings the monitor is running with; a change restarts it.
    private struct HotkeyBindings: Equatable {
        let binding: HotkeyBinding
        let undo: HotkeyBinding
    }

    public private(set) var phase: Phase = .idle
    public private(set) var hotkeyState: HotkeyState = .stopped
    /// The latest message for the HUD; cleared after the notice time in Settings.
    public private(set) var notice: DictationNotice?
    /// Microphone level while recording, 0...1.
    public private(set) var inputLevel: Float = 0
    /// Where the caret was when recording started, for placing the HUD; `nil` if unknown.
    public private(set) var caretRect: CGRect?
    /// The last dictated text, for the menu's *Copy Last Dictation*.
    public private(set) var lastText: String?

    let dependencies: Dependencies
    @ObservationIgnored var gesture: HotkeyGesture
    /// Bumped whenever ``gesture`` is replaced, so a timer the old gesture asked for is dropped
    /// instead of reaching the new one.
    @ObservationIgnored private var gestureGeneration = 0
    /// Timing from Settings that changed mid-gesture; applied once the gesture is idle.
    @ObservationIgnored private var pendingGestureConfiguration: HotkeyGestureConfiguration?
    @ObservationIgnored private var runningBindings: HotkeyBindings?
    /// The recording was started from the menu, not the hotkey, so the gesture knows nothing of it.
    @ObservationIgnored var startedFromMenu = false
    @ObservationIgnored private var started: ContinuousClock.Instant
    @ObservationIgnored private var operations: Task<Void, Never>?
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
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
    /// change elsewhere in Settings never interrupts a dictation.
    public func applySettings() {
        let settings = dependencies.settings()
        startHotkeys(settings.dictation)
        let recorder = dependencies.recorder
        let permission = dependencies.microphonePermission
        let keepReady = settings.dictation.enabled && settings.dictation.keepMicrophoneReady
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

    private func startHotkeys(_ settings: DictationSettings) {
        updateGesture(Self.gestureConfiguration(settings))
        guard settings.enabled else {
            stopHotkeys()
            hotkeyState = .disabled
            return
        }
        let bindings = HotkeyBindings(
            binding: HotkeyBinding(storageString: settings.hotkey) ?? .defaultDictation,
            undo: HotkeyBinding(storageString: settings.undoHotkey) ?? .defaultUndo
        )
        if bindings == runningBindings, case .running = hotkeyState { return }
        // Stop, start with the new binding, then reset the gesture: a release the old tap never
        // delivered must not leave it held.
        stopHotkeys()
        do {
            let events = try dependencies.hotkeys.start(binding: bindings.binding, undoBinding: bindings.undo)
            runningBindings = bindings
            hotkeyState = .running(hotkey: bindings.binding.displayName)
            eventsTask = Task { [weak self] in
                for await event in events {
                    self?.handle(event)
                }
            }
        } catch HotkeyError.permissionDenied {
            hotkeyState = .needsAccessibility
        } catch {
            Log.dictation.error("The dictation hotkey could not start: \(error.localizedDescription, privacy: .public)")
            hotkeyState = .failed(error.localizedDescription)
        }
        gesture.reset()
    }

    /// Ends the monitor. A recording the hotkey was driving is discarded, since its release can
    /// no longer arrive.
    private func stopHotkeys() {
        eventsTask?.cancel()
        eventsTask = nil
        runningBindings = nil
        dependencies.hotkeys.stop()
        if gesture.isRecording {
            gesture.reset()
            enqueue { await self.discardRecording(notice: nil) }
        }
    }

    /// Takes new gesture timing now if idle, otherwise once the current gesture ends.
    private func updateGesture(_ configuration: HotkeyGestureConfiguration) {
        guard configuration != gesture.configuration else {
            pendingGestureConfiguration = nil
            return
        }
        guard !gesture.isRecording else {
            pendingGestureConfiguration = configuration
            return
        }
        gesture = HotkeyGesture(configuration: configuration)
        gestureGeneration += 1
        pendingGestureConfiguration = nil
    }

    static func gestureConfiguration(_ settings: DictationSettings) -> HotkeyGestureConfiguration {
        HotkeyGestureConfiguration(
            tapMaxMs: settings.tapMaxMs,
            doubleTapWindowMs: settings.doubleTapWindowMs,
            handsFreeEnabled: settings.handsFreeEnabled
        )
    }

    // MARK: - Hotkey events

    func handle(_ event: HotkeyEvent) {
        guard let input = event.gestureInput else {
            undoLastEdit()
            return
        }
        if input == .escape, phase == .processing {
            cancelProcessing()
            return
        }
        if startedFromMenu, !gesture.isRecording {
            // A menu dictation is hands-free: Esc cancels it and the hotkey stops it.
            switch input {
            case .escape: cancel()
            case .pressed: toggleDictation()
            default: break
            }
            return
        }
        apply(gesture.handle(input, atMs: elapsedMs()), cause: input)
    }

    private func apply(_ actions: [HotkeyAction], cause: HotkeyInput) {
        for action in actions {
            perform(action, cause: cause)
        }
        if let pending = pendingGestureConfiguration, !gesture.isRecording {
            updateGesture(pending)
        }
    }

    private func perform(_ action: HotkeyAction, cause: HotkeyInput) {
        switch action {
        case .startRecording:
            enqueue { await self.beginRecording(handsFree: false) }
        case .enteredHandsFree:
            enqueue { self.enterHandsFree() }
        case .stopAndProcess:
            enqueue { await self.finishRecording() }
        case .cancel:
            // A lone tap or a shortcut typed with the hotkey held is not a mistake worth a message.
            let notice: DictationNotice? = cause == .escape ? .cancelled : nil
            enqueue { await self.discardRecording(notice: notice) }
        case .scheduleTimer(let ms):
            // Every timer the gesture asks for fires exactly once and is never cancelled; the
            // gesture recognises one left over from an earlier tap. Only a timer that outlived
            // its gesture (replaced when the timing changed) is dropped.
            let generation = gestureGeneration
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(ms))
                self?.timerFired(generation: generation)
            }
        }
    }

    private func timerFired(generation: Int) {
        guard generation == gestureGeneration else { return }
        apply(gesture.handle(.timerFired, atMs: elapsedMs()), cause: .timerFired)
    }

    private func enterHandsFree() {
        if case .recording = phase { phase = .recording(handsFree: true) }
    }

    // MARK: - Menu and HUD intents

    /// Starts a hands-free dictation, or stops the current one: for the menu, without the hotkey.
    public func toggleDictation() {
        switch phase {
        case .idle:
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
    public func showMicrophoneNotice(_ message: String) {
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
