import Foundation
import Shared

/// Composes the cleanup model's instruction for a request: the base rules, the level's rules,
/// the vocabulary and the placeholder rule, each from its own function.
///
/// Without the fine-tuned adapter the model cannot resolve spoken self-corrections reliably (see
/// ``Prompt/cleanup``), so every level gets the strict keep-every-word rules; with it, Medium
/// and High ask for the correction only. Medium with the adapter and nothing else to add is
/// exactly ``Prompt/adapted``, the prompt the adapter was trained on.
public struct PromptBuilder: Sendable, Equatable {
    /// Whether the fine-tuned adapter is fused into the model.
    public let adapted: Bool
    /// One template for every request, for prompt experiments; `nil` composes one per request.
    public let override: PromptTemplate?

    public init(adapted: Bool, override: PromptTemplate? = nil) {
        self.adapted = adapted
        self.override = override
    }

    /// The template for `options`. The ``CleanupLevel/none`` level never reaches the model; it
    /// gets Light's rules.
    public func template(for options: CleanupOptions) -> PromptTemplate {
        if let override { return override }
        let rules = Self.baseRules
            + Self.levelRules(for: options.level, adapted: adapted)
            + [Self.unchangedRule]
            + [Self.vocabularyRule(options.vocabulary), Self.placeholderRule(options.placeholders)].compactMap { $0 }
            + [Self.outputRule]
        return PromptTemplate(system: rules.joined(separator: "\n"), examples: [])
    }

    static let baseRules = [
        "Correct transcription errors, punctuation, casing and grammar in the TEXT.",
        "Preserve meaning, tone, hedging and filler intent exactly.",
    ]
    static let unchangedRule = "If the text is already correct, return it unchanged."
    static let outputRule = "Output only the corrected text."

    /// What the model may change. A self-correction is resolved only with the adapter.
    static func levelRules(for level: CleanupLevel, adapted: Bool) -> [String] {
        let resolves = adapted && level.resolvesSelfCorrections
        switch (level.allowsRewording, resolves) {
        case (false, false):
            return ["Do not add, remove, summarise or rephrase content."]
        case (false, true):
            return [
                "Do not add, summarise or rephrase content.",
                "When the speaker corrects themselves, keep only the correction.",
            ]
        case (true, false):
            return ["You may reword lightly for grammar and clarity. Do not add, remove or summarise content."]
        case (true, true):
            return [
                "You may reword lightly for grammar and clarity. Do not add or summarise content.",
                "When the speaker corrects themselves, keep only the correction.",
            ]
        }
    }

    /// The user's terms, in the order given; `nil` when there are none.
    static func vocabularyRule(_ terms: [String]) -> String? {
        let cleaned = unique(terms.map(singleLine).filter { !$0.isEmpty })
        guard !cleaned.isEmpty else { return nil }
        return "Spell these names and terms exactly as written: \(cleaned.joined(separator: ", "))."
    }

    /// Tells the model to copy placeholder tokens through; `nil` when there are none.
    static func placeholderRule(_ tokens: [String]) -> String? {
        let cleaned = unique(tokens.map(singleLine).filter { !$0.isEmpty })
        guard !cleaned.isEmpty else { return nil }
        return "Copy each of these tokens exactly once, unchanged: \(cleaned.joined(separator: ", "))."
    }

    /// A term on one line, so user text cannot add lines to the instruction.
    private static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
