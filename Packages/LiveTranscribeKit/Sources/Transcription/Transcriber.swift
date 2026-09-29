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
    /// A folder (the path) without config.json and the .safetensors weights.
    case modelNotFound(String)
    /// A model of a kind the app can't run; `modelType` is nil when its config.json doesn't say.
    case unsupportedModel(name: String, modelType: String?)
    case unsupportedSampleRate(Int)

    public var errorDescription: String? {
        switch self {
        case .modelNotLoaded: "The speech-to-text model is not loaded."
        case .invalidModelID(let id):
            "Invalid speech-to-text model id: \(id). Enter a Hugging Face repository ID or a model folder's path."
        case .modelNotFound(let path):
            "No speech-to-text model in \(path): the folder needs the model's config.json and .safetensors weights."
        case .unsupportedModel(let name, let modelType?):
            "\(name) is a \(modelType) model, which Live Transcribe can't run. It runs \(Self.runnable)."
        case .unsupportedModel(let name, nil):
            "Live Transcribe can't tell what kind of speech-to-text model \(name) is: its config.json has no model_type."
        case .unsupportedSampleRate(let rate): "Audio must be 16 kHz (got \(rate) Hz)."
        }
    }

    private static var runnable: String {
        ListFormatter.localizedString(byJoining: SpeechModelKind.all.map(\.modelType))
    }
}
