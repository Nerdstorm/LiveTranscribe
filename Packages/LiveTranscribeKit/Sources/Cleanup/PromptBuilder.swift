import Foundation
import Shared

/// Composes the cleanup model's instruction for a request: the base rules, the level's rules,
/// the vocabulary and the placeholder rule, each from its own function.
///
/// Without the fine-tuned adapter the model cannot resolve spoken self-corrections reliably (see
/// ``Prompt/cleanup``), so every level gets the strict keep-every-word rules; with it, Medium
/// and High ask for the correction only. Medium with the adapter and nothing else to add is
/// exactly ``Prompt/adapted``, the prompt the adapter was trained on.
///
/// Deep has its own instruction, with or without the adapter (``deepRules(multiline:)``).
public struct PromptBuilder: Sendable, Equatable {
    /// Whether the fine-tuned adapter is loaded alongside the model.
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
        let levelRules = options.level.repairsAcrossSentences
            ? Self.deepRules(multiline: options.multiline)
            : Self.baseRules + Self.levelRules(for: options.level, adapted: adapted)
        let rules = levelRules
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

    /// Deep's instruction: general rules for reading the whole dictation and writing what the
    /// speaker meant, with no worked examples. ``SelfRepair`` checks the answer against the same
    /// rules. In a field that takes several lines, the model lays out emails, letters and lists
    /// itself; in a one-line field it may not break lines.
    static func deepRules(multiline: Bool) -> [String] {
        let rules = [
            "The TEXT was dictated and written down by speech recognition, which can mishear words. Read all of it and work out what the speaker meant.",
            "Correct words the recognition got wrong, using the rest of the text, and fix punctuation, casing and grammar.",
            "When the speaker corrects themselves, keep only the correction, even when it comes in a later sentence or is worded badly.",
            "Keep \"no\", \"sorry\", \"actually\" and similar words when they answer a question, apologise or start a new point.",
            "Keep every name, number, date, time and negation as the speaker said it. Do not add anything they did not say, and do not summarise.",
            "Keep the speaker's own words wherever they are right.",
        ]
        let layout = multiline
            ? "Lay the text out the way it would be written: an email or letter with its greeting, paragraphs and sign-off on separate lines; items or steps as a list, numbered when their order matters. Leave ordinary sentences as sentences."
            : "Write it as one paragraph, without line breaks."
        return rules + [layout]
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
