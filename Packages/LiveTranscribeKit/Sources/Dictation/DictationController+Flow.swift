import ApplicationServices
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
            setPhase(.idle)
            return show(.captureFailed(error.localizedDescription))
        }
        let target = await lookup
        guard !target.isSecure else {
            // Nothing recorded here is ever transcribed.
            await dependencies.recorder.cancel()
            gesture.reset()
            setPhase(.idle)
            return show(.secureField)
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
        setPhase(.idle)
        show(notice)
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

        if let failure = recording.failure, recording.samples.isEmpty {
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
        guard !output.isEmpty else { return finish(.nothingHeard) }

        let preceding = Self.characterBeforeCaret(in: target)
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
                latencyMs: latencyMs
            ))
        }
        if recording.truncated {
            return finish(.recordingTruncated(seconds: settings.dictation.maxRecordingSeconds))
        }
        finish(Self.notice(for: result, app: target.app?.name))
    }

    private func finish(_ notice: DictationNotice?) {
        processingTask = nil
        setPhase(.idle)
        show(notice)
    }

    private func save(_ record: DictationRecord) async {
        do {
            try await dependencies.history.append(record)
        } catch {
            Log.dictation.error("The dictation could not be saved to history: \(error.localizedDescription, privacy: .public)")
        }
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
        if result.succeeded || result == .copiedToClipboard {
            undoEntry = nil
        }
        show(Self.notice(for: result))
    }

    // MARK: - Mapping

    static func characterBeforeCaret(in target: InsertionTarget) -> Character? {
        guard let element = target.element,
              let value = element.string(kAXValueAttribute),
              let selection = element.range(kAXSelectedTextRangeAttribute)
        else { return nil }
        return InsertionSpacing.character(before: selection, in: value)
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

    static func notice(for result: InsertionResult, app: String?) -> DictationNotice? {
        switch result {
        case .inserted, .nothingToInsert: nil
        case .copiedToClipboard: .copiedToClipboard(app: app)
        case .refusedSecureField: .secureField
        case .failed: .insertionFailed
        }
    }

    static func notice(for result: UndoResult) -> DictationNotice {
        switch result {
        case .replacedInPlace: .undone
        case .undoneAndInserted(let inserted): inserted.isInserted ? .undone : .undoCopiedToClipboard
        case .copiedToClipboard: .undoCopiedToClipboard
        case .refusedDifferentApp: .undoRefused("Switch back to the app you dictated into to undo")
        case .refusedFieldChanged: .undoRefused("The text was edited since, so it wasn't undone")
        case .refusedSecureField: .secureField
        case .failed: .undoFailed
        }
    }
}
