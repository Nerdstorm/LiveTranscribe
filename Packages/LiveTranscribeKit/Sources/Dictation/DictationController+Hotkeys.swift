import Foundation
import Hotkey
import Shared

/// The hotkey monitor: starting it with the bindings from Settings, turning its events into
/// gesture steps, stopping it, and pausing it while a shortcut recorder needs the keys.
extension DictationController {
    /// The hotkey settings the monitor is running with; a change restarts it.
    struct HotkeyBindings: Equatable {
        let binding: HotkeyBinding
        let undo: HotkeyBinding
    }

    // MARK: - Suspension

    /// Pauses the dictation and undo shortcuts until the returned suspension ends, so a shortcut
    /// recorder receives every key itself. The keyboard tap would otherwise see them first: fn
    /// would start a dictation, and a combination already in use would be swallowed.
    ///
    /// Suspensions can overlap; the shortcuts resume, with the settings current then, once the
    /// last one ends. A dictation being recorded when the first one starts is discarded
    /// silently, and none can start until the last one ends. One already being processed
    /// finishes. The microphone and ``hotkeyState`` are left as they are.
    public func suspendHotkeys() -> HotkeySuspension {
        lastSuspensionID += 1
        let id = lastSuspensionID
        let wasSuspended = hotkeysSuspended
        activeSuspensions.insert(id)
        if !wasSuspended { pauseHotkeys() }
        return HotkeySuspension { [weak self] in self?.endSuspension(id) }
    }

    /// Ends one suspension; the shortcuts resume when it was the last, unless the controller was
    /// stopped meanwhile. An unknown or already ended identifier is ignored, so a suspension can
    /// never end twice.
    private func endSuspension(_ id: Int) {
        guard activeSuspensions.remove(id) != nil, activeSuspensions.isEmpty else { return }
        Log.dictation.info("Dictation shortcuts no longer paused")
        startHotkeys(dependencies.settings().dictation)
    }

    private func pauseHotkeys() {
        Log.dictation.info("Dictation shortcuts paused while a shortcut is recorded")
        stopHotkeys()
        // A dictation started from the menu is dropped too: its text would land in the recorder's
        // window. Nothing happens if no recording is running or queued.
        gesture.reset()
        enqueue { await self.discardRecording(notice: nil) }
    }

    // MARK: - Monitor

    /// Starts the monitor with `settings`' bindings, unless it already runs them, the controller
    /// is stopped, dictation is off, or the shortcuts are suspended.
    func startHotkeys(_ settings: DictationSettings) {
        updateGesture(Self.gestureConfiguration(settings))
        // Stopped: `start()` starts the monitor, not a settings change or a suspension ending.
        guard isStarted else { return }
        guard settings.enabled else {
            stopHotkeys()
            hotkeyState = .disabled
            return
        }
        // Resuming starts it with the settings current then; `hotkeyState` keeps its value.
        guard !hotkeysSuspended else { return }
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
                    // A stream still hands over what it holds after its monitor stops. Such an
                    // event is from the old shortcut or from before a pause: a press would start
                    // a recording no release can end, an undo would type into the recorder.
                    guard !Task.isCancelled else { return }
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
    func stopHotkeys() {
        eventsTask?.cancel()
        eventsTask = nil
        runningBindings = nil
        dependencies.hotkeys.stop()
        if gesture.isRecording {
            gesture.reset()
            enqueue { await self.discardRecording(notice: nil) }
        }
    }

    // MARK: - Events

    /// Turns one event from the monitor into gesture steps, which run in arrival order.
    func handle(_ event: HotkeyEvent) {
        guard let input = event.gestureInput else {
            undoLastEdit()
            return
        }
        if phase == .processing, !gesture.isRecording {
            // One dictation at a time: a recording started now would open the microphone only
            // after this one is inserted, and lose the first words.
            switch input {
            case .escape: cancelProcessing()
            case .pressed: showProgress(.stillProcessing)
            default: break
            }
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

    // MARK: - Gesture timing

    /// Takes new gesture timing now if idle, otherwise once the current gesture ends.
    func updateGesture(_ configuration: HotkeyGestureConfiguration) {
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
}
