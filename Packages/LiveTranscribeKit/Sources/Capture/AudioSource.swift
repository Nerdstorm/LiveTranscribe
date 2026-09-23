import Foundation

/// A source of 16 kHz mono Float32 audio (see `AudioFormat`).
///
/// `start()` returns a stream of sample buffers. The stream finishes normally after `stop()`,
/// or throws a ``CaptureError`` if capture fails and cannot be recovered.
public protocol AudioSource: Actor {
    func start() async throws -> AsyncThrowingStream<[Float], Error>
    func stop() async
}

/// Why capture could not start, or stopped for good. Each description is shown to the user.
public enum CaptureError: LocalizedError, Equatable {
    /// Nothing capture may use on its own is connected.
    case noInputDevice
    case unsupportedFormat(String)
    case startFailed(String)
    case restartFailed(attempts: Int)
    /// The chosen microphone is missing and there is no physical microphone to fall back to.
    /// (With one, capture falls back and reports ``CaptureNotice/fellBackToDefault(missing:using:)``.)
    case inputDeviceUnavailable
    case tooManyRestarts(restarts: Int)
    case alreadyRunning
    case unreadableFile(String)

    public var errorDescription: String? {
        switch self {
        case .noInputDevice:
            "No microphone is available."
        case .unsupportedFormat(let detail):
            "The microphone's audio format is not supported: \(detail)"
        case .startFailed(let detail):
            "Audio capture could not start: \(detail)"
        case .restartFailed(let attempts):
            "The microphone stopped and capture could not restart after \(attempts) attempts."
        case .inputDeviceUnavailable:
            "The selected microphone isn't connected and no other microphone can be used instead. "
                + "Connect it, or choose another one from the microphone menu."
        case .tooManyRestarts(let restarts):
            "Audio capture failed and restarted \(restarts) times in a minute, so it was stopped. "
                + "Choose a different microphone."
        case .alreadyRunning:
            "Capture is already running."
        case .unreadableFile(let detail):
            "The audio file could not be read: \(detail)"
        }
    }
}

extension CaptureError {
    /// The error a recovery that gave up ends the stream with. A missing device says more than a
    /// generic restart failure, so it is passed on as it is.
    static func afterFailedRecovery(lastError: (any Error)?, attempts: Int) -> CaptureError {
        switch lastError as? CaptureError {
        case .noInputDevice?: .noInputDevice
        case .inputDeviceUnavailable?: .inputDeviceUnavailable
        default: .restartFailed(attempts: attempts)
        }
    }
}
