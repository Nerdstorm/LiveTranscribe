import Shared

/// One of the requests a cleanup makes of the model: what its prompt allows, and the limits its
/// answer is checked against.
///
/// Standard asks once, with ``rewording``. When the text has a correction cue ("sorry", "no", "I
/// mean"), it asks twice: ``correcting`` resolves the self-correction and changes nothing else,
/// as the self-correction adapter was trained to (``Prompt/adapted``), then ``rewording`` rewords
/// what that left. Deep asks with ``repairing``.
public enum CleanupPass: String, CaseIterable, Sendable {
    /// Standard's first pass when it hears a correction cue: fix the text and resolve the
    /// correction, without rewording.
    case correcting
    /// Standard's own pass: fix the text and resolve corrections, and reword lightly for grammar
    /// and clarity.
    case rewording
    /// Deep's pass, with its own prompt and check (``SelfRepair``).
    case repairing

    /// The pass a request at `level` makes unless the executor asks for another. None never
    /// reaches the model.
    public init(_ level: CleanupLevel) {
        self = level.repairsAcrossSentences ? .repairing : .rewording
    }

    /// The model may reword, not only correct, so a run of spoken words may be replaced.
    public var allowsRewording: Bool { self == .rewording }

    /// Allowed ratio of the cleaned text's word count to the input's. Rewording needs more room.
    /// Deep's own check replaces these limits, so its bounds, Standard's, are not used.
    public var wordRatioBounds: ClosedRange<Double> {
        switch self {
        case .correcting: 0.5...1.2
        case .rewording, .repairing: 0.4...1.3
        }
    }
}
