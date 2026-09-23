import Dictation
import Session

extension DictationReadiness {
    /// Whether dictation can use the models the live transcript session loads.
    ///
    /// The models are shared, so dictation waits for them to load and gives way to a running
    /// transcript. A session that failed after loading (microphone, capture or saving) still has
    /// its models, so dictation stays available.
    public init(sessionPhase: SessionPhase) {
        switch sessionPhase {
        case .notLoaded, .loading:
            self = .modelsLoading
        case .ready:
            self = .ready
        case .listening, .stopping:
            self = .liveTranscriptRunning
        case .failed(.modelLoadFailed(_, let message)):
            self = .modelsUnavailable(message)
        case .failed(.microphonePermissionDenied), .failed(.audioCaptureFailed), .failed(.persistenceFailed):
            self = .ready
        }
    }
}
