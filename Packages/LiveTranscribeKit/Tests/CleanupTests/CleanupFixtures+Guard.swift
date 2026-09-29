@testable import Cleanup
import Foundation
import Shared
import Testing

extension CleanupFixtures {
    /// guard.jsonl: the output guard's verdict on each case at every level, and the parts it
    /// judges by (the words, cues, alignment, names and content it counts), so a difference shows
    /// where it starts. guard-policy.json: the default policy, word lists included.
    enum Guard {
        /// A raw text, what the model made of it, the placeholders it holds, and changes to the
        /// default policy.
        struct Case {
            let raw: String
            let outcome: GenerationOutcome
            var placeholders: [String] = []
            var policy: Policy?
        }

        /// Changes to the default policy, for the cases that test its settings. A word-ratio
        /// table replaces the default one; levels missing from it use their own bounds.
        struct Policy: Encodable {
            var wordRatioBounds: [CleanupLevel: ClosedRange<Double>]?
            var minSimilarity: Double?
            var preambles: [String]?
            var correctionCues: [String]?
            var fillers: [String]?
            var negations: [String]?
            var functionWords: [String]?
            var maxDroppedRun: Int?
            var maxDroppedContent: Int?
            var maxRetractedWords: Int?
            var minRespellingSimilarity: Double?
            var requiresIntactPlaceholders: Bool?
            var requiresNamesInPlace: Bool?

            var applied: OutputGuard.Policy {
                var policy = OutputGuard.Policy.default
                if let wordRatioBounds { policy.wordRatioBounds = wordRatioBounds }
                if let minSimilarity { policy.minSimilarity = minSimilarity }
                if let preambles { policy.preambles = preambles }
                if let correctionCues { policy.correctionCues = correctionCues }
                if let fillers { policy.fillers = fillers }
                if let negations { policy.negations = negations }
                if let functionWords { policy.functionWords = functionWords }
                if let maxDroppedRun { policy.maxDroppedRun = maxDroppedRun }
                if let maxDroppedContent { policy.maxDroppedContent = maxDroppedContent }
                if let maxRetractedWords { policy.maxRetractedWords = maxRetractedWords }
                if let minRespellingSimilarity { policy.minRespellingSimilarity = minRespellingSimilarity }
                if let requiresIntactPlaceholders { policy.requiresIntactPlaceholders = requiresIntactPlaceholders }
                if let requiresNamesInPlace { policy.requiresNamesInPlace = requiresNamesInPlace }
                return policy
            }

            private enum CodingKeys: String, CodingKey {
                case wordRatioBounds, minSimilarity, preambles, correctionCues, fillers, negations, functionWords
                case maxDroppedRun, maxDroppedContent, maxRetractedWords, minRespellingSimilarity
                case requiresIntactPlaceholders, requiresNamesInPlace
            }

            func encode(to encoder: any Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encodeIfPresent(wordRatioBounds.map(Guard.bounds), forKey: .wordRatioBounds)
                try container.encodeIfPresent(minSimilarity.map(CleanupFixtures.number), forKey: .minSimilarity)
                try container.encodeIfPresent(preambles, forKey: .preambles)
                try container.encodeIfPresent(correctionCues, forKey: .correctionCues)
                try container.encodeIfPresent(fillers, forKey: .fillers)
                try container.encodeIfPresent(negations, forKey: .negations)
                try container.encodeIfPresent(functionWords, forKey: .functionWords)
                try container.encodeIfPresent(maxDroppedRun, forKey: .maxDroppedRun)
                try container.encodeIfPresent(maxDroppedContent, forKey: .maxDroppedContent)
                try container.encodeIfPresent(maxRetractedWords, forKey: .maxRetractedWords)
                try container.encodeIfPresent(minRespellingSimilarity.map(CleanupFixtures.number), forKey: .minRespellingSimilarity)
                try container.encodeIfPresent(requiresIntactPlaceholders, forKey: .requiresIntactPlaceholders)
                try container.encodeIfPresent(requiresNamesInPlace, forKey: .requiresNamesInPlace)
            }
        }

        struct DefaultPolicy: Encodable {
            let wordRatioBounds: [String: [String]]
            /// Each level's own bounds, which a policy uses for a level missing from its table.
            let levelWordRatioBounds: [String: [String]]
            let minSimilarity: String
            let preambles: [String]
            let correctionCues: [String]
            let fillers: [String]
            let negations: [String]
            let functionWords: [String]
            let maxDroppedRun: Int
            let maxDroppedContent: Int
            let maxRetractedWords: Int
            let minRespellingSimilarity: String
            let requiresIntactPlaceholders: Bool
            let requiresNamesInPlace: Bool
        }

        struct Line: Encodable {
            let raw: String
            let outcome: Outcome
            let placeholders: [String]
            let policy: Policy?
            /// By level.
            let verdicts: [String: Verdict]
            /// For a completed generation only.
            let parts: Parts?
        }

        struct Outcome: Encodable {
            var completed: String?
            var timedOut: String?
            var cancelled: Bool?
            var failed: String?
        }

        struct Verdict: Encodable {
            var accepted: String?
            var rejected: Reason?
        }

        struct Gap: Encodable {
            let deleted: [Int]
            let inserted: [Int]
        }

        /// What the guard judges a completed generation by, from the raw text and the trimmed
        /// output.
        struct Parts: Encodable {
            let rawWords: [String]
            let cleanedWords: [String]
            let rawCues: Int
            let cleanedCues: Int
            let isCorrection: Bool
            let keepsPlaceholders: Bool
            let matches: [Int?]
            let gaps: [Gap]
            let droppedRun: Int?
            let losesNegation: Bool
            let names: [Int]
            let movesOrDropsName: Bool
            let droppedContent: Int
            let similarity: String
            /// Absent when the raw text has no words.
            let wordRatio: String?
        }

        static func defaultPolicyLine() throws -> String {
            let policy = OutputGuard.Policy.default
            return try CleanupFixtures.line(DefaultPolicy(
                wordRatioBounds: bounds(policy.wordRatioBounds),
                levelWordRatioBounds: bounds(Dictionary(uniqueKeysWithValues: CleanupLevel.allCases.map { ($0, $0.wordRatioBounds) })),
                minSimilarity: number(policy.minSimilarity),
                preambles: policy.preambles,
                correctionCues: policy.correctionCues,
                fillers: policy.fillers,
                negations: policy.negations,
                functionWords: policy.functionWords,
                maxDroppedRun: policy.maxDroppedRun,
                maxDroppedContent: policy.maxDroppedContent,
                maxRetractedWords: policy.maxRetractedWords,
                minRespellingSimilarity: number(policy.minRespellingSimilarity),
                requiresIntactPlaceholders: policy.requiresIntactPlaceholders,
                requiresNamesInPlace: policy.requiresNamesInPlace
            ))
        }

        static func lines() throws -> [String] {
            try cases.map { try CleanupFixtures.line(line(for: $0)) }
        }

        static func bounds(_ table: [CleanupLevel: ClosedRange<Double>]) -> [String: [String]] {
            Dictionary(uniqueKeysWithValues: table.map { level, range in
                (level.rawValue, [number(range.lowerBound), number(range.upperBound)])
            })
        }

        private static func line(for testCase: Case) -> Line {
            let policy = testCase.policy?.applied ?? .default
            let outputGuard = OutputGuard(policy: policy)
            var verdicts: [String: Verdict] = [:]
            for level in CleanupLevel.allCases {
                let options = CleanupOptions(level: level, placeholders: testCase.placeholders)
                switch outputGuard.review(raw: testCase.raw, outcome: testCase.outcome, options: options) {
                case .accepted(let text): verdicts[level.rawValue] = Verdict(accepted: text)
                case .rejected(let reason): verdicts[level.rawValue] = Verdict(rejected: Reason(reason))
                }
            }
            var outcome = Outcome()
            var parts: Parts?
            switch testCase.outcome {
            case .completed(let output):
                outcome.completed = output
                parts = Self.parts(raw: testCase.raw, output: output, placeholders: testCase.placeholders, policy: policy)
            case .timedOut(let seconds): outcome.timedOut = number(seconds)
            case .cancelled: outcome.cancelled = true
            case .failed(let message): outcome.failed = message
            }
            return Line(
                raw: testCase.raw,
                outcome: outcome,
                placeholders: testCase.placeholders,
                policy: testCase.policy,
                verdicts: verdicts,
                parts: parts
            )
        }

        private static func parts(raw: String, output: String, placeholders: [String], policy: OutputGuard.Policy) -> Parts {
            let cleaned = output.trimmingCharacters(in: .whitespacesAndNewlines)
            let rawWords = EditDistance.words(in: EditDistance.normalize(raw))
            let cleanedWords = EditDistance.words(in: EditDistance.normalize(cleaned))
            let selfCorrection = SelfCorrection(policy: policy)
            let droppedWords = DroppedWords(policy: policy)
            let spokenNames = SpokenNames(policy: policy)
            let alignment = WordAlignment(raw: rawWords, cleaned: cleanedWords)
            let ignored = Set(placeholders.map(EditDistance.normalize))
            let rawWordCount = EditDistance.words(in: raw).count
            return Parts(
                rawWords: rawWords,
                cleanedWords: cleanedWords,
                rawCues: selfCorrection.cueCount(in: rawWords),
                cleanedCues: selfCorrection.cueCount(in: cleanedWords),
                isCorrection: selfCorrection.isCorrection(raw: rawWords, cleaned: cleanedWords),
                keepsPlaceholders: OutputGuard.keepsPlaceholders(placeholders, raw: raw, cleaned: cleaned),
                matches: alignment.matches,
                gaps: alignment.gaps.map { Gap(deleted: $0.deleted, inserted: $0.inserted) },
                droppedRun: droppedWords.droppedRun(in: alignment),
                losesNegation: droppedWords.losesNegation(raw: rawWords, cleaned: cleanedWords),
                names: spokenNames.nameIndices(in: raw, words: rawWords, ignoring: ignored),
                movesOrDropsName: spokenNames.movesOrDropsName(in: raw, alignment: alignment, ignoring: ignored),
                droppedContent: ContentWords(policy: policy).droppedCount(in: alignment, ignoring: ignored),
                similarity: number(EditDistance.normalizedSimilarity(raw, cleaned)),
                wordRatio: rawWordCount > 0 ? number(Double(EditDistance.words(in: cleaned).count) / Double(rawWordCount)) : nil
            )
        }
    }
}
