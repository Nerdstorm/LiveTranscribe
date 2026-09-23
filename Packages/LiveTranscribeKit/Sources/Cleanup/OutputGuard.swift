import Foundation
import Shared
import Styles

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
    /// A self-correction was resolved at a level that keeps every spoken word.
    case selfCorrectionNotAllowed
    /// A snippet placeholder was dropped, repeated or altered.
    case placeholderChanged
    /// A run of spoken words was deleted with nothing in its place, and no cue explains it.
    case droppedWords(count: Int)
    /// A negation ("not", "never", "can't") was removed.
    case lostNegation
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
        case .selfCorrectionNotAllowed: "resolved a self-correction at a level that keeps every word"
        case .placeholderChanged: "changed a snippet placeholder"
        case .droppedWords(let count): "dropped \(count) spoken words"
        case .lostNegation: "dropped a negation"
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
/// The model is asked only to correct, so output that is empty, chatty, much longer or shorter
/// than the level allows, or substantially different from the input is treated as a meaning
/// change and rejected. So is output that damaged a snippet placeholder, since the snippet could
/// then not be put back.
///
/// Output that drops a correction cue ("sorry", "I mean", …) is checked by ``SelfCorrection``
/// instead of the length and similarity limits: dropping a cue is acceptable only as part of
/// removing a spoken self-correction. This catches the model's most harmful mistake, keeping
/// the words the speaker took back and dropping their correction, which is often short enough
/// to pass the length and similarity limits. At a level that keeps every word (Light), dropping
/// a cue is always rejected.
///
/// Output that keeps every cue is checked by ``DroppedWords``: it may not remove a negation and,
/// unless the level allows rewording (High), may not delete a run of spoken words outright.
public struct OutputGuard: Sendable {
    public struct Policy: Sendable, Equatable {
        /// Allowed ratio of the output's word count to the input's, per level. A level missing
        /// from the table uses ``CleanupLevel/wordRatioBounds``.
        public var wordRatioBounds: [CleanupLevel: ClosedRange<Double>]
        /// Minimum ``EditDistance/normalizedSimilarity(_:_:)`` between raw and cleaned text.
        public var minSimilarity: Double
        /// Lowercased openings that signal the model is talking about the text, not returning it.
        public var preambles: [String]
        /// Phrases that introduce a spoken self-correction, as in "cars, sorry, buses".
        public var correctionCues: [String]
        /// Filler words that may be dropped along with a self-correction.
        public var fillers: [String]
        /// Words that negate what follows; removing one reverses the meaning.
        public var negations: [String]
        /// Longest run of spoken words that output keeping every cue may delete outright.
        public var maxDroppedRun: Int
        /// Most words a self-correction may retract before its cue.
        public var maxRetractedWords: Int
        /// Minimum similarity for a word that was not spoken to count as a respelling of one
        /// that was, inside a self-correction.
        public var minRespellingSimilarity: Double

        public init(
            wordRatioBounds: [CleanupLevel: ClosedRange<Double>],
            minSimilarity: Double,
            preambles: [String],
            correctionCues: [String],
            fillers: [String],
            negations: [String],
            maxDroppedRun: Int,
            maxRetractedWords: Int,
            minRespellingSimilarity: Double
        ) {
            self.wordRatioBounds = wordRatioBounds
            self.minSimilarity = minSimilarity
            self.preambles = preambles
            self.correctionCues = correctionCues
            self.fillers = fillers
            self.negations = negations
            self.maxDroppedRun = maxDroppedRun
            self.maxRetractedWords = maxRetractedWords
            self.minRespellingSimilarity = minRespellingSimilarity
        }

        /// The bounds for `level`.
        public func wordRatioBounds(for level: CleanupLevel) -> ClosedRange<Double> {
            wordRatioBounds[level] ?? level.wordRatioBounds
        }

        public static let `default` = Policy(
            wordRatioBounds: Dictionary(uniqueKeysWithValues: CleanupLevel.allCases.map { ($0, $0.wordRatioBounds) }),
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
            fillers: FillerRemover.standardFillers,
            negations: ["not", "never", "no", "nothing", "nobody", "none", "neither", "nor", "nowhere", "cannot", "without"],
            maxDroppedRun: 1,
            maxRetractedWords: 6,
            minRespellingSimilarity: 0.6
        )
    }

    public let policy: Policy
    private let selfCorrection: SelfCorrection
    private let droppedWords: DroppedWords

    public init(policy: Policy = .default) {
        self.policy = policy
        self.selfCorrection = SelfCorrection(policy: policy)
        self.droppedWords = DroppedWords(policy: policy)
    }

    /// Whether `cleaned` has fewer correction cues than `raw`, so that ``review(raw:outcome:)``
    /// judges it as a self-correction removal.
    public func dropsCorrectionCue(raw: String, cleaned: String) -> Bool {
        correctionCueCount(in: cleaned) < correctionCueCount(in: raw)
    }

    /// Occurrences of the policy's correction cues in `text`.
    public func correctionCueCount(in text: String) -> Int {
        selfCorrection.cueCount(in: EditDistance.words(in: EditDistance.normalize(text)))
    }

    /// Whether `outcome` may replace `raw`, the text the model was given, under `options`.
    public func review(raw: String, outcome: GenerationOutcome, options: CleanupOptions) -> GuardVerdict {
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

        guard Self.keepsPlaceholders(options.placeholders, raw: raw, cleaned: cleaned) else {
            return .rejected(.placeholderChanged)
        }

        let cleanedWords = EditDistance.words(in: EditDistance.normalize(cleaned))
        if selfCorrection.dropsCue(raw: rawWords, cleaned: cleanedWords) {
            guard options.level.resolvesSelfCorrections else { return .rejected(.selfCorrectionNotAllowed) }
            return selfCorrection.isCorrection(raw: rawWords, cleaned: cleanedWords)
                ? .accepted(cleaned)
                : .rejected(.invalidSelfCorrection)
        }
        if !options.level.allowsRewording, let count = droppedWords.droppedRun(raw: rawWords, cleaned: cleanedWords) {
            return .rejected(.droppedWords(count: count))
        }
        if droppedWords.losesNegation(raw: rawWords, cleaned: cleanedWords) {
            return .rejected(.lostNegation)
        }

        let rawWordCount = EditDistance.words(in: raw).count
        if rawWordCount > 0 {
            let ratio = Double(EditDistance.words(in: cleaned).count) / Double(rawWordCount)
            if !policy.wordRatioBounds(for: options.level).contains(ratio) {
                return .rejected(.wordRatio(ratio))
            }
        }

        let similarity = EditDistance.normalizedSimilarity(raw, cleaned)
        if similarity < policy.minSimilarity {
            return .rejected(.lowSimilarity(similarity))
        }
        return .accepted(cleaned)
    }

    /// Every expected placeholder comes back exactly once, and no other token appears or is
    /// left half-changed. A placeholder retracted by a self-correction also fails: dropping it
    /// would silently lose a snippet the speaker may have wanted.
    static func keepsPlaceholders(_ placeholders: [String], raw: String, cleaned: String) -> Bool {
        guard placeholders.allSatisfy({ PlaceholderToken.occurrences(of: $0, in: cleaned) == 1 }) else { return false }
        return PlaceholderToken.openingCount(in: cleaned) == PlaceholderToken.openingCount(in: raw)
            && PlaceholderToken.closingCount(in: cleaned) == PlaceholderToken.closingCount(in: raw)
    }
}
