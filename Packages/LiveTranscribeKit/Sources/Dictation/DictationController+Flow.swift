import Foundation
import Insertion
import Persistence
import Shared

/// The steps of one dictation, run in order by ``DictationController/enqueue(_:)``.
extension DictationController {
    func beginRecording(handsFree: Bool) async {
        guard phase == .idle else {
            gesture.reset()
            return
        }
        // A new attempt: the last dictation's caret may be in another app or on another display.
        // Until the new field is read, the HUD and any refusal show where the pointer is.
        setCaret(nil)
        guard !hotkeysSuspended else {
            // Queued just before a shortcut recorder paused the hotkeys; dropped silently.
            return refuse(nil)
        }
        switch await dependencies.readiness() {
        case .ready:
            break
        case .modelsLoading:
            return refuse(.modelsLoading)
        case .modelsUnavailable(let detail):
            return refuse(.modelsUnavailable(detail))
        case .liveTranscriptRunning:
            return refuse(.liveTranscriptRunning)
        }
        switch dependencies.microphonePermission.status() {
        case .granted:
            break
        case .undetermined:
            // The system prompt takes the key press; the user dictates again once they answer.
            refuse(nil)
            _ = await dependencies.microphonePermission.request()
            return
        case .denied:
            return refuse(.microphoneDenied)
        }

        // The microphone opens first and the focused field is read meanwhile: Accessibility can
        // wait on a busy app, and the first word must not be lost to that wait.
        async let lookup = currentTarget()
        cancelRequested = false
        setPhase(.recording(handsFree: handsFree))
        do {
            try await dependencies.recorder.start()
        } catch {
            Log.dictation.error("Recording could not start: \(error.localizedDescription, privacy: .public)")
            _ = await lookup
            gesture.reset()
            return endDictation(showing: [.captureFailed(error.localizedDescription)])
        }
        let target = await lookup
        guard !target.isSecure else {
            // Nothing recorded here is ever transcribed.
            await dependencies.recorder.cancel()
            gesture.reset()
            return endDictation(showing: [.secureField])
        }
        setCaret(target.caretRect)
    }

    /// Ends a gesture that could not record, with a message.
    private func refuse(_ notice: DictationNotice?) {
        gesture.reset()
        startedFromMenu = false
        show(notice)
    }

    func discardRecording(notice: DictationNotice?) async {
        guard case .recording = phase else { return }
        await dependencies.recorder.cancel()
        endDictation(showing: notice.map { [$0] } ?? [])
    }

    /// Capture ended by itself during the recording: it ends now with what was heard, rather
    /// than showing *Listening* while nothing arrives until the key is released. The event can
    /// be read late, so it applies only if the recording in progress is the one that lost capture.
    func endRecordingWithoutCapture() async {
        guard case .recording = phase, await dependencies.recorder.hasLostCapture else { return }
        Log.dictation.notice("The microphone stopped during the recording; ending it with what was heard")
        // The key may still be held; its release then finds the gesture idle and does nothing.
        gesture.reset()
        await finishRecording()
    }

    func cancelProcessing() {
        cancelRequested = true
        processingTask?.cancel()
    }

    func finishRecording() async {
        guard case .recording = phase else { return }
        setPhase(.processing)
        let releasedAt = dependencies.now()
        let recording = await dependencies.recorder.stop()
        let settings = dependencies.settings()

        // Too little arrived before capture failed to transcribe: the failure is the news.
        if let failure = recording.failure,
           recording.samples.isEmpty || recording.durationMs < settings.dictation.minUtteranceMs {
            return finish(.captureFailed(failure))
        }
        guard recording.durationMs >= settings.dictation.minUtteranceMs else {
            return finish(.nothingHeard)
        }
        let target = await currentTarget()
        guard !target.isSecure else { return finish(.secureField) }

        async let snippets = dependencies.snippets()
        async let vocabulary = dependencies.vocabulary()
        let configuration = DictationProcessor.Configuration(
            level: settings.cleanupLevel,
            snippets: await snippets,
            vocabulary: await vocabulary,
            vocabularyPromptLimit: settings.dictation.vocabularyPromptLimit,
            vocabularySimilarityThreshold: settings.dictation.vocabularySimilarityThreshold,
            multiline: target.isMultiline
        )
        let processor = dependencies.processor
        let samples = recording.samples
        let processing = Task { try await processor.process(samples, configuration: configuration) }
        processingTask = processing
        let output: DictationProcessor.Output
        do {
            output = try await processing.value
        } catch is CancellationError {
            return finish(.cancelled)
        } catch {
            Log.dictation.error("Dictation failed: \(error.localizedDescription, privacy: .public)")
            return finish(.transcriptionFailed(error.localizedDescription))
        }
        processingTask = nil
        guard !cancelRequested else { return finish(.cancelled) }
        guard !output.isEmpty else { return finish(recording.failure.map { .captureFailed($0) } ?? .nothingHeard) }

        let preceding = await Self.characterBeforeCaret(in: target)
        // Esc may have been pressed while the field was read; nothing is inserted yet.
        guard !cancelRequested else { return finish(.cancelled) }
        let text = InsertionSpacing.adjusted(output.text, after: preceding)
        let result = await dependencies.delivery.insert(text, into: target)
        let insertedAt = dependencies.now()
        let latencyMs = releasedAt.duration(to: insertedAt).wholeMilliseconds
        Log.dictation.info("""
            Dictation delivered by \(Self.delivery(of: result), privacy: .public) in \(latencyMs) ms \
            (STT \(output.transcriptionMs) ms, cleanup \(output.cleanupMs) ms\(output.fellBack ? ", fell back" : "", privacy: .public))
            """)

        if let record = InsertionRecord(text: text, result: result, target: target, insertedAt: insertedAt) {
            undoEntry = UndoEntry(record: record, uncleaned: InsertionSpacing.adjusted(output.uncleanedText, after: preceding))
        } else {
            undoEntry = nil
        }
        setLastText(output.text)
        if settings.dictation.historyEnabled {
            await save(DictationRecord(
                id: UUID(),
                createdAt: Date(),
                appName: target.app?.name,
                bundleIdentifier: target.app?.bundleIdentifier,
                rawText: output.rawTranscript,
                cleanedText: output.text,
                cleanupLevel: settings.cleanupLevel.rawValue,
                fellBack: output.fellBack,
                fallbackReason: output.fallbackReason,
                delivery: Self.delivery(of: result),
                audioDurationMs: recording.durationMs,
                latencyMs: latencyMs,
                captureFailure: recording.failure
            ))
        }
        // Where the text went comes first: it may be waiting on the clipboard for ⌘V.
        finish(
            Self.notice(for: result, app: target.app?.name, accessibilityGranted: dependencies.accessibility.isGranted()),
            Self.notice(for: recording, limitSeconds: settings.dictation.maxRecordingSeconds)
        )
    }

    /// Ends the dictation with `notices`, most important first; `nil`s are skipped.
    private func finish(_ notices: DictationNotice?...) {
        processingTask = nil
        endDictation(showing: notices.compactMap { $0 })
    }

    /// Saves the dictation, then prunes the history if its retention is due.
    private func save(_ record: DictationRecord) async {
        do {
            try await dependencies.history.append(record)
        } catch {
            Log.dictation.error("The dictation could not be saved to history: \(error.localizedDescription, privacy: .public)")
            return
        }
        pruneHistoryIfDue()
    }

    func performUndo() async {
        // Undo only between dictations: during one, ⌘Z would land in the middle of it.
        guard phase == .idle else { return }
        // Its notice goes by the field it acts on, once read; the last dictation's caret may be
        // in another app by now.
        setCaret(nil)
        let settings = dependencies.settings().dictation
        guard let entry = undoEntry,
              entry.record.insertedAt.duration(to: dependencies.now()) <= .seconds(settings.undoWindowSeconds)
        else {
            undoEntry = nil
            return show(.nothingToUndo)
        }
        guard entry.uncleaned != entry.record.text else {
            // Cleanup changed nothing, so there is no edit to undo.
            return show(.nothingToUndo)
        }
        let target = await currentTarget()
        setCaret(target.caretRect)
        let result = await dependencies.delivery.undo(entry.record, replacingWith: entry.uncleaned, in: target)
        if result.succeeded || result.sentUndoKeystroke || result == .copiedToClipboard {
            // Once ⌘Z has gone to the app, trying again would undo something else.
            undoEntry = nil
        }
        show(Self.notice(for: result))
    }

    // MARK: - Mapping

    /// The character before the caret, for spacing; read off the main actor, like
    /// ``currentTarget()``, because Accessibility calls wait on the other app.
    nonisolated static func characterBeforeCaret(in target: InsertionTarget) async -> Character? {
        guard let element = target.element else { return nil }
        return await Task.detached { element.characterBeforeSelection() }.value
    }

    static func delivery(of result: InsertionResult) -> String {
        switch result {
        case .inserted(let method, _): method.rawValue
        case .copiedToClipboard: "clipboard"
        case .refusedSecureField: "refused"
        case .nothingToInsert: "nothing"
        case .failed: "failed"
        }
    }

    /// What the HUD says about where the text went; `nil` when it simply went in.
    ///
    /// - Parameter accessibilityGranted: Read only when the paste was not permitted: macOS
    ///   refuses keystrokes without Accessibility, and sometimes, with it on, until the app reopens.
    static func notice(
        for result: InsertionResult,
        app: String?,
        accessibilityGranted: @autoclosure () -> Bool
    ) -> DictationNotice? {
        switch result {
        case .inserted, .nothingToInsert: nil
        case .copiedToClipboard(.notAccepted): .copiedToClipboard(app: app)
        case .copiedToClipboard(.focusMoved): .copiedAfterFocusMoved
        case .copiedToClipboard(.pasteNotPermitted): .pasteNotAllowed(needsReopen: accessibilityGranted())
        case .refusedSecureField: .secureField
        case .failed: .insertionFailed
        }
    }

    /// What the user should know about a recording that did not hear all they said: it hit the
    /// length limit, or the microphone stopped partway through.
    static func notice(for recording: DictationRecorder.Recording, limitSeconds: Int) -> DictationNotice? {
        if recording.truncated { return .recordingTruncated(seconds: limitSeconds) }
        guard recording.failure != nil else { return nil }
        // Rounded, and never "after 0 s": something was heard.
        return .captureStoppedEarly(afterSeconds: max(1, (recording.durationMs + 500) / 1_000))
    }

    static func notice(for result: UndoResult) -> DictationNotice {
        switch result {
        case .replacedInPlace: .undone
        case .undoneAndInserted(let inserted):
            switch inserted {
            case .inserted, .nothingToInsert: .undone
            case .copiedToClipboard: .undoCopiedToClipboard
            // Focus turned to a password field between ⌘Z and the insert.
            case .refusedSecureField: .secureField
            case .failed: .undoFailed
            }
        case .copiedToClipboard: .undoCopiedToClipboard
        case .refusedDifferentApp: .undoRefused("Switch back to the app you dictated into to undo")
        case .refusedFocusMoved: .undoRefused("Click back into the field you dictated into to undo")
        case .refusedFieldChanged: .undoRefused("The text was edited since, so it wasn't undone")
        case .refusedSecureField: .secureField
        case .failed: .undoFailed
        }
    }
}
