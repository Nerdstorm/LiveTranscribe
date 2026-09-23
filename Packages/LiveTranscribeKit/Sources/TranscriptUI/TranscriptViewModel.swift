import Capture
import Foundation
import Observation
import Session
import Shared

/// State for the transcript window, driven by ``SessionEvent``s on the main actor.
@MainActor
@Observable
public final class TranscriptViewModel {
    public private(set) var phase: SessionPhase = .notLoaded
    public private(set) var cleanup: CleanupAvailability = .pending
    /// Latest progress per model, in the order the models started loading.
    public private(set) var modelProgress: [ModelLoadProgress] = []
    public private(set) var lines: [TranscriptLine] = []
    public private(set) var warning: String?
    public private(set) var transcriptFile: URL?
    /// Connected microphones, for the picker.
    public private(set) var inputDevices: [AudioInputDevice] = []
    /// The chosen microphone's UID; `nil` follows the system default input.
    public private(set) var selectedInputDeviceUID: String?
    public private(set) var systemDefaultInputName: String?

    private let session: any SessionControlling
    public let sessionsDirectory: URL?
    private let inputSelection: (any InputDeviceSelecting)?
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var deviceChangesTask: Task<Void, Never>?
    /// Cleanup state captured when the current session started; decides whether raw lines wait.
    @ObservationIgnored private var sessionCleansText = false

    public init(
        session: any SessionControlling,
        sessionsDirectory: URL?,
        inputSelection: (any InputDeviceSelecting)? = nil
    ) {
        self.session = session
        self.sessionsDirectory = sessionsDirectory
        self.inputSelection = inputSelection
    }

    /// Subscribes to session events and starts loading models. Idempotent.
    public func attach() {
        guard eventsTask == nil else { return }
        let events = session.events
        eventsTask = Task { [weak self] in
            for await event in events {
                self?.apply(event)
            }
        }
        if let inputSelection {
            refreshInputDevices()
            let changes = inputSelection.changes()
            deviceChangesTask = Task { [weak self] in
                for await _ in changes {
                    self?.refreshInputDevices()
                }
            }
        }
        Task { await session.prepare() }
    }

    // MARK: - Intents

    public func toggleListening() {
        switch phase {
        case .listening: Task { await session.stop() }
        case .ready, .failed(.microphonePermissionDenied), .failed(.audioCaptureFailed), .failed(.persistenceFailed):
            Task { await session.start() }
        default: break
        }
    }

    public func retryLoading() {
        Task { await session.prepare() }
    }

    public func cancelLoading() {
        Task { await session.cancelPreparation() }
    }

    public func retryCleanup() {
        Task { await session.retryCleanup() }
    }

    /// Shows a microphone change reported by capture (a new default, or a fallback) in the
    /// warning banner.
    public func showCaptureNotice(_ message: String) {
        warning = message
    }

    public func dismissWarning() {
        warning = nil
    }

    /// Chooses the microphone for the next session; `nil` follows the system default input.
    public func selectInputDevice(_ uid: String?) {
        guard canChangeInputDevice, let inputSelection else { return }
        inputSelection.select(uid)
        selectedInputDeviceUID = uid
    }

    // MARK: - Derived state

    public var isListening: Bool { phase == .listening }

    public var canToggleListening: Bool {
        switch phase {
        case .ready, .listening, .failed(.microphonePermissionDenied), .failed(.audioCaptureFailed),
             .failed(.persistenceFailed):
            true
        case .notLoaded, .loading, .stopping, .failed(.modelLoadFailed):
            false
        }
    }

    public var supportsInputSelection: Bool { inputSelection != nil }

    /// The microphone is fixed for the duration of a session.
    public var canChangeInputDevice: Bool {
        inputSelection != nil && phase != .listening && phase != .stopping
    }

    /// The saved microphone is not connected. Capture falls back to the system default, and says
    /// so, until it reconnects or another is chosen.
    public var selectedInputDeviceIsMissing: Bool {
        guard let selectedInputDeviceUID else { return false }
        return !inputDevices.contains { $0.id == selectedInputDeviceUID }
    }

    /// Final text of every line, one per paragraph, for copying.
    public var transcriptText: String {
        lines.filter { $0.state != .partial }.map(\.text).joined(separator: "\n")
    }

    // MARK: - Events

    public func apply(_ event: SessionEvent) {
        switch event {
        case .phase(let newPhase):
            phase = newPhase
            if newPhase == .ready { modelProgress.removeAll() }
        case .modelProgress(let progress):
            if let index = modelProgress.firstIndex(where: { $0.modelID == progress.modelID }) {
                modelProgress[index] = progress
            } else {
                modelProgress.append(progress)
            }
        case .cleanupAvailability(let availability):
            cleanup = availability
        case .sessionStarted(_, let file):
            lines.removeAll()
            transcriptFile = file
            sessionCleansText = cleanup == .available
        case .partial(let id, let text):
            if let index = lines.firstIndex(where: { $0.id == id }) {
                guard lines[index].state == .partial else { return }
                lines[index].text = text
            } else {
                lines.append(TranscriptLine(id: id, text: text, rawText: nil, state: .partial))
            }
        case .transcribed(let segment):
            upsert(TranscriptLine(
                id: segment.id,
                text: segment.rawText,
                rawText: segment.rawText,
                state: .raw(awaitingCleanup: sessionCleansText)
            ))
        case .cleaned(let cleaned):
            upsert(TranscriptLine(
                id: cleaned.segment.id,
                text: cleaned.cleanedText,
                rawText: cleaned.segment.rawText,
                state: cleaned.fellBack ? .fellBack(reason: cleaned.fallbackReason ?? "unknown") : .cleaned
            ))
        case .discarded(let id):
            lines.removeAll { $0.id == id && $0.state == .partial }
        case .warning(let message):
            warning = message
        }
    }

    private func refreshInputDevices() {
        guard let inputSelection else { return }
        inputDevices = inputSelection.availableDevices()
        systemDefaultInputName = inputSelection.systemDefaultName()
        selectedInputDeviceUID = inputSelection.selectedDeviceUID
    }

    private func upsert(_ line: TranscriptLine) {
        if let index = lines.firstIndex(where: { $0.id == line.id }) {
            lines[index] = line
        } else {
            lines.append(line)
        }
    }
}
