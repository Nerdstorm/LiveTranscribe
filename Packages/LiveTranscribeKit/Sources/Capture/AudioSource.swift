import Foundation

/// A source of 16 kHz mono Float32 audio (see `AudioFormat`).
///
/// `start()` returns a stream of sample buffers. The stream finishes normally after `stop()`,
/// or throws a ``CaptureError`` if capture fails and cannot be recovered.
public protocol AudioSource: Actor {
    func start() async throws -> AsyncThrowingStream<[Float], Error>
    func stop() async
}

public enum CaptureError: LocalizedError, Equatable {
    case noInputDevice
    case unsupportedFormat(String)
    case startFailed(String)
    case restartFailed(attempts: Int)
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
            "The selected microphone isn't connected. Choose another one from the microphone menu."
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
