import Foundation
import Shared

/// Speech-to-text over one segment of 16 kHz mono audio.
public protocol Transcriber: Actor {
    func load(progress: @escaping ModelLoadProgressHandler) async throws
    func transcribe(_ samples: [Float], sampleRate: Int) async throws -> String
}

public enum TranscriptionError: LocalizedError, Equatable {
    case modelNotLoaded
    case invalidModelID(String)
    case unsupportedSampleRate(Int)

    public var errorDescription: String? {
        switch self {
        case .modelNotLoaded: "The speech-to-text model is not loaded."
        case .invalidModelID(let id): "Invalid speech-to-text model id: \(id)"
        case .unsupportedSampleRate(let rate): "Audio must be 16 kHz (got \(rate) Hz)."
        }
    }
}
