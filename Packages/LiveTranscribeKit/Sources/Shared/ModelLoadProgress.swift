/// Progress of downloading, loading or warming up one model.
public struct ModelLoadProgress: Sendable, Equatable {
    public enum Stage: String, Sendable, Equatable {
        case downloading
        case loading
        case warmingUp
        case ready
    }

    /// Hugging Face repository id, e.g. `mlx-community/parakeet-tdt-0.6b-v3`.
    public let modelID: String
    public let stage: Stage
    /// Fraction in 0...1, or `nil` when the stage has no measurable progress.
    public let fractionCompleted: Double?

    public init(modelID: String, stage: Stage, fractionCompleted: Double? = nil) {
        self.modelID = modelID
        self.stage = stage
        self.fractionCompleted = fractionCompleted.map { min(max($0, 0), 1) }
    }
}

public typealias ModelLoadProgressHandler = @Sendable (ModelLoadProgress) -> Void
