import Foundation
import HuggingFace

/// Where the model the Speech-to-text setting names is.
public enum SpeechModelLocation: Equatable, Sendable {
    /// A Hugging Face repository, downloaded into the Hugging Face cache the first time.
    case repository(Repo.ID)
    /// A folder on this Mac that holds what such a repository holds: config.json and the
    /// .safetensors weights. Nothing is downloaded.
    case folder(URL)

    /// Reads the setting. A path (it starts with `/` or `~`) is a folder; anything else must be a
    /// repository ID, such as `Nerdstorm/Qwen3-ASR-0.6B-Sinhala-8bit`.
    public init(setting: String) throws(TranscriptionError) {
        let text = setting.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("/") || text.hasPrefix("~") {
            let path = (text as NSString).expandingTildeInPath
            self = .folder(URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL)
        } else if let id = Repo.ID(rawValue: text), !id.namespace.isEmpty, !id.name.isEmpty,
                  !id.name.contains("/"), !text.contains(where: \.isWhitespace) {
            self = .repository(id)
        } else {
            throw .invalidModelID(setting)
        }
    }

    /// The model's name: the repository's (without its owner), or the folder's.
    public var name: String {
        switch self {
        case .repository(let id): id.name
        case .folder(let url): url.lastPathComponent
        }
    }
}

extension SpeechModelLocation: CustomStringConvertible {
    /// For logs: the repository ID, or the folder's name without its path, which holds the user's
    /// name.
    public var description: String {
        switch self {
        case .repository(let id): id.rawValue
        case .folder(let url): "folder \(url.lastPathComponent)"
        }
    }
}
