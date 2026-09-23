import Foundation
import Shared

/// How a cleanup generation ended.
public enum GenerationOutcome: Sendable, Equatable {
    case completed(String)
    case timedOut(seconds: Double)
    case cancelled
    case failed(String)
}

/// Why cleaned text was rejected in favour of the raw text.
public enum FallbackReason: Sendable, Equatable, CustomStringConvertible {
    case emptyOutput
    case thinkingLeaked
    case preamble(String)
    case wordRatio(Double)
    case lowSimilarity(Double)
    /// A correction cue was dropped, but the removed words were not a self-correction.
    case invalidSelfCorrection
    case timedOut(seconds: Double)
    case cancelled
    case generationFailed(String)

    public var description: String {
        switch self {
        case .emptyOutput: "empty output"
        case .thinkingLeaked: "thinking tags in output"
        case .preamble(let phrase): "preamble in output (\(phrase))"
        case .wordRatio(let ratio): String(format: "word-count ratio %.2f outside allowed range", ratio)
        case .lowSimilarity(let similarity): String(format: "similarity %.2f below threshold", similarity)
        case .invalidSelfCorrection: "removed words that were not a self-correction"
        case .timedOut(let seconds): String(format: "timed out after %.1fs", seconds)
        case .cancelled: "cancelled"
        case .generationFailed(let message): "generation failed: \(message)"
        }
    }
}

public enum GuardVerdict: Sendable, Equatable {
    case accepted(String)
    case rejected(FallbackReason)
}

/// Decides whether the LLM's output can replace the raw transcript.
///
/// The model is asked only to correct, so output that is empty, chatty, much longer or shorter,
/// or substantially different from the input is treated as a meaning change and rejected.
///
/// Output that drops a correction cue ("sorry", "I mean", …) is checked by ``SelfCorrection``
/// instead of the length and similarity limits: dropping a cue is acceptable only as part of
/// removing a spoken self-correction. This catches the model's most harmful mistake, keeping
/// the words the speaker took back and dropping their correction, which is often short enough
/// to pass the length and similarity limits.
public struct OutputGuard: Sendable {
    public struct Policy: Sendable, Equatable {
        public var minWordRatio: Double
        public var maxWordRatio: Double
        /// Minimum ``EditDistance/normalizedSimilarity(_:_:)`` between raw and cleaned text.
        public var minSimilarity: Double
        /// Lowercased openings that signal the model is talking about the text, not returning it.
        public var preambles: [String]
        /// Phrases that introduce a spoken self-correction, as in "cars, sorry, buses".
        public var correctionCues: [String]
        /// Filler words that may be dropped along with a self-correction.
        public var fillers: [String]
        /// Most words a self-correction may retract before its cue.
        public var maxRetractedWords: Int
        /// Minimum similarity for a word that was not spoken to count as a respelling of one
        /// that was, inside a self-correction.
        public var minRespellingSimilarity: Double

        public init(
            minWordRatio: Double,
            maxWordRatio: Double,
            minSimilarity: Double,
            preambles: [String],
            correctionCues: [String],
            fillers: [String],
            maxRetractedWords: Int,
            minRespellingSimilarity: Double
        ) {
            self.minWordRatio = minWordRatio
            self.maxWordRatio = maxWordRatio
            self.minSimilarity = minSimilarity
            self.preambles = preambles
            self.correctionCues = correctionCues
            self.fillers = fillers
            self.maxRetractedWords = maxRetractedWords
            self.minRespellingSimilarity = minRespellingSimilarity
        }

        public static let `default` = Policy(
            minWordRatio: 0.7,
            maxWordRatio: 1.3,
            minSimilarity: 0.6,
            preambles: [
                "here is", "here's", "here are", "sure,", "sure!", "sure.", "certainly",
                "of course", "corrected text", "the corrected", "corrected:", "correction:",
                "output:", "text:", "context:",
            ],
            correctionCues: [
                "sorry", "i mean", "i meant", "no", "wait", "rather", "actually", "make that",
                "scratch that", "correction",
            ],
            fillers: ["um", "uh", "uhm", "erm", "er", "ah", "hmm"],
            maxRetractedWords: 6,
            minRespellingSimilarity: 0.6
        )
    }

    public let policy: Policy
    private let selfCorrection: SelfCorrection

    public init(policy: Policy = .default) {
        self.policy = policy
        self.selfCorrection = SelfCorrection(policy: policy)
    }

    public func review(raw: String, outcome: GenerationOutcome) -> GuardVerdict {
        let output: String
        switch outcome {
        case .completed(let text): output = text
        case .timedOut(let seconds): return .rejected(.timedOut(seconds: seconds))
        case .cancelled: return .rejected(.cancelled)
        case .failed(let message): return .rejected(.generationFailed(message))
        }

        let cleaned = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return .rejected(.emptyOutput) }

        let lowered = cleaned.lowercased()
        if lowered.contains("<think") || lowered.contains("</think>") {
            return .rejected(.thinkingLeaked)
        }

        let rawWords = EditDistance.words(in: EditDistance.normalize(raw))
        // An opening the speaker said is not a preamble, however either side punctuates it.
        if let phrase = policy.preambles.first(where: {
            lowered.hasPrefix($0) && !rawWords.starts(with: EditDistance.words(in: EditDistance.normalize($0)))
        }) {
            return .rejected(.preamble(phrase))
        }

        let cleanedWords = EditDistance.words(in: EditDistance.normalize(cleaned))
        if selfCorrection.dropsCue(raw: rawWords, cleaned: cleanedWords) {
            return selfCorrection.isCorrection(raw: rawWords, cleaned: cleanedWords)
                ? .accepted(cleaned)
                : .rejected(.invalidSelfCorrection)
        }

        let rawWordCount = EditDistance.words(in: raw).count
        if rawWordCount > 0 {
            let ratio = Double(EditDistance.words(in: cleaned).count) / Double(rawWordCount)
            if ratio < policy.minWordRatio || ratio > policy.maxWordRatio {
                return .rejected(.wordRatio(ratio))
            }
        }

        let similarity = EditDistance.normalizedSimilarity(raw, cleaned)
        if similarity < policy.minSimilarity {
            return .rejected(.lowSimilarity(similarity))
        }
        return .accepted(cleaned)
    }
}
