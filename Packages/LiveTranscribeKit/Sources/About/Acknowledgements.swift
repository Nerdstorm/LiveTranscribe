import Foundation

/// The licence notices of the open-source Swift packages the app is built with.
///
/// `Acknowledgements.json` is generated from Package.resolved and the packages' own files by
/// `scripts/generate-acknowledgements.sh`; AboutTests checks that it still matches.
public struct Acknowledgements: Decodable, Equatable, Sendable {
    public struct Package: Decodable, Equatable, Sendable {
        /// The repository's name, such as "mlx-swift".
        public let name: String
        /// The version in Package.resolved, or the start of the commit for a package pinned by revision.
        public let version: String
        public let url: String
        /// The package's own licence first, then those of the code it bundles.
        public let notices: [Notice]
    }

    public struct Notice: Decodable, Equatable, Sendable {
        /// Where the text comes from, relative to the package.
        public let file: String
        public let text: String
    }

    public let packages: [Package]

    public enum LoadError: Error, Equatable {
        case missing
    }

    /// The notices that ship with the app.
    public static func bundled() throws -> Acknowledgements {
        guard let url = Bundle.module.url(forResource: "Acknowledgements", withExtension: "json") else {
            throw LoadError.missing
        }
        return try JSONDecoder().decode(Acknowledgements.self, from: Data(contentsOf: url))
    }
}

/// A model the app downloads on first launch, credited to the people who made it.
///
/// The models are not part of the app, but the About panel names them and their licences, as
/// the README's *Models and credits* section does.
public struct ModelCredit: Equatable, Sendable {
    /// What the app uses it for.
    public let role: String
    /// The Hugging Face repository the app downloads.
    public let repository: String
    /// The model it is converted from, and who made it.
    public let original: String
    public let licence: String

    /// The default models (``AppSettings/defaults``), which AboutTests keeps in step.
    public static let defaults: [ModelCredit] = [
        ModelCredit(
            role: "Speech-to-text",
            repository: "mlx-community/parakeet-tdt-0.6b-v3",
            original: "Parakeet TDT 0.6B v3 by NVIDIA",
            licence: "CC BY 4.0"
        ),
        ModelCredit(
            role: "Cleanup",
            repository: "mlx-community/Qwen3-1.7B-4bit",
            original: "Qwen3-1.7B by the Qwen team, Alibaba Cloud, with this app's own self-correction adapter (MIT)",
            licence: "Apache-2.0"
        ),
        ModelCredit(
            role: "Voice activity detection",
            repository: "mlx-community/silero-vad",
            original: "Silero VAD by the Silero team",
            licence: "MIT"
        ),
    ]
}
