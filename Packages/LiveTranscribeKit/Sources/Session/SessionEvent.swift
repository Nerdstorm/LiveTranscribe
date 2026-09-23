import Foundation
import Shared

public enum SessionFailure: Sendable, Equatable {
    case microphonePermissionDenied
    case modelLoadFailed(model: String, message: String)
    case audioCaptureFailed(message: String)
    case persistenceFailed(message: String)
}

/// Lifecycle of the session: models load once, then listening can start and stop repeatedly.
public enum SessionPhase: Sendable, Equatable {
    case notLoaded
    case loading
    case ready
    case listening
    /// Capture has stopped; queued segments are still being transcribed and cleaned.
    case stopping
    case failed(SessionFailure)
}

public enum CleanupAvailability: Sendable, Equatable {
    /// Turned off in settings; the LLM is never loaded.
    case disabled
    /// Enabled but not loaded yet.
    case pending
    case available
    /// Loading failed; transcripts are raw-only until a retry succeeds.
    case unavailable(model: String, message: String)
}

/// Everything the UI needs to render the session. Delivered in order on ``SessionControlling/events``.
public enum SessionEvent: Sendable, Equatable {
    case phase(SessionPhase)
    case modelProgress(ModelLoadProgress)
    case cleanupAvailability(CleanupAvailability)
    case sessionStarted(sessionID: UUID, transcriptFile: URL?)
    /// Live text for a segment still being spoken. Never cleaned.
    case partial(segmentID: UUID, text: String)
    /// Final raw text. Final on screen unless a `.cleaned` for the same segment follows.
    case transcribed(Segment)
    case cleaned(CleanedSegment)
    /// A segment produced no text (noise, or STT failed); drop any partial shown for it.
    case discarded(segmentID: UUID)
    case warning(String)
}

/// The UI's view of the session. Implemented by ``SessionCoordinator``; faked in tests.
public protocol SessionControlling: Sendable {
    var events: AsyncStream<SessionEvent> { get }
    /// Loads (downloading if needed) every model. Safe to call again after a load failure.
    func prepare() async
    func cancelPreparation() async
    func start() async
    /// Stops capture, then waits until queued segments are transcribed, cleaned and saved.
    func stop() async
    func retryCleanup() async
    /// Stops everything and flushes storage; for app termination.
    func shutdown() async
}
