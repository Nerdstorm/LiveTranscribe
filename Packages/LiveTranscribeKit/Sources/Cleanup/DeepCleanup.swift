import Foundation

/// How the Deep level asks the model to repair a dictation: in one pass or after Standard's
/// correcting pass, with which adapter, thinking or not, what it shows when its repair is turned
/// down, and within what budget.
///
/// The shipped values were chosen by measuring each choice on the same examples (`Train measure`,
/// docs/design-notes.md). Tools vary them to compare; the app uses ``shipped``.
public struct DeepCleanup: Sendable, Equatable {
    public enum Passes: String, Sendable, Equatable, CaseIterable {
        /// One Deep generation of the text.
        case one
        /// When the text has a correction cue, Standard's correcting pass first (the adapter, on
        /// the prompt it was trained on) resolves what it can, then the Deep pass repairs the rest.
        case afterCorrecting
    }

    public var passes: Passes
    /// The adapter on during the Deep pass: Deep's own, trained on Deep's prompts; the
    /// self-correction adapter, trained on Standard's correcting prompt only (``Prompt/adapted``);
    /// or none.
    public var adapter: CleanupRequest.Adapter
    /// Qwen3 reasons in a `<think>` block before answering. The reasoning is removed before the
    /// answer is checked, and an answer whose reasoning never finished falls back.
    public var thinking: Bool
    /// Tokens the model may spend reasoning, on top of the answer's budget.
    public var thinkingTokens: Int
    /// When Deep's repair is turned down and the correcting pass hasn't run, whether Standard's
    /// cleanup runs in the time left, so Deep shows what Standard would have. Its answer must pass
    /// Deep's check too; one that fails it falls back with Deep's reason.
    public var fallsBackToStandard: Bool
    /// Deep's shortest deadline for the whole cleanup; the Advanced timeout applies when it is longer.
    public var minimumTimeoutSeconds: Double

    public init(
        passes: Passes,
        adapter: CleanupRequest.Adapter,
        thinking: Bool,
        thinkingTokens: Int,
        fallsBackToStandard: Bool,
        minimumTimeoutSeconds: Double
    ) {
        self.passes = passes
        self.adapter = adapter
        self.thinking = thinking
        self.thinkingTokens = thinkingTokens
        self.fallsBackToStandard = fallsBackToStandard
        self.minimumTimeoutSeconds = minimumTimeoutSeconds
    }

    /// What the app runs: one pass with Deep's adapter, without thinking, which was right on
    /// 108 of 114 hand-written cases, against 88 with the self-correction adapter and 52 with
    /// none; with thinking and no adapter, 58, taking 20 times as long (docs/design-notes.md). A
    /// repair `SelfRepair` turns down gets Standard's cleanup instead, if `SelfRepair` accepts that.
    public static let shipped = DeepCleanup(
        passes: .one,
        adapter: .deep,
        thinking: false,
        thinkingTokens: 768,
        fallsBackToStandard: true,
        minimumTimeoutSeconds: 8
    )

    /// The deadline for a cleanup under `timeoutSeconds`, the Advanced setting.
    public func deadline(given timeoutSeconds: Double) -> Double {
        max(timeoutSeconds, minimumTimeoutSeconds)
    }
}
