import Foundation
import Shared

/// One text to measure cleanup on, with what the app should show and what a wrong answer would get
/// wrong. Unlike ``TrainingExample`` it is never trained on, and it can describe Deep's cases:
/// corrections across sentences, layout, and the facts an answer must keep.
public struct EvalCase: Codable, Sendable, Equatable {
    public var id: String
    /// What the case measures ("cross-sentence", "control", "grammar", …), for the report's rows.
    public var category: String
    /// Earlier lines, sent as read-only context.
    public var context: [String]
    public var raw: String
    public var target: String
    /// Other answers that are just as right.
    public var alternatives: [String]
    /// The field takes several lines, so Deep may lay the text out.
    public var multiline: Bool
    /// Words or phrases a right answer keeps (a name, a number, "don't"). An accepted answer
    /// without one changed the meaning.
    public var keep: [String]
    /// Words or phrases a right answer never has (a retracted value, an invented claim). An
    /// accepted answer with one changed the meaning.
    public var avoid: [String]

    public init(
        id: String,
        category: String,
        context: [String] = [],
        raw: String,
        target: String,
        alternatives: [String] = [],
        multiline: Bool = false,
        keep: [String] = [],
        avoid: [String] = []
    ) {
        self.id = id
        self.category = category
        self.context = context
        self.raw = raw
        self.target = target
        self.alternatives = alternatives
        self.multiline = multiline
        self.keep = keep
        self.avoid = avoid
    }

    enum CodingKeys: String, CodingKey {
        case id, category, context, raw, target, alternatives, multiline, keep, avoid
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        category = try container.decode(String.self, forKey: .category)
        context = try container.decodeIfPresent([String].self, forKey: .context) ?? []
        raw = try container.decode(String.self, forKey: .raw)
        target = try container.decodeIfPresent(String.self, forKey: .target) ?? ""
        alternatives = try container.decodeIfPresent([String].self, forKey: .alternatives) ?? []
        multiline = try container.decodeIfPresent(Bool.self, forKey: .multiline) ?? false
        keep = try container.decodeIfPresent([String].self, forKey: .keep) ?? []
        avoid = try container.decodeIfPresent([String].self, forKey: .avoid) ?? []
    }

    /// Reads JSON Lines of eval cases, or of ``TrainingExample``s, which become cases with their
    /// category's name. Cases without an id get the file's name and line number.
    public static func read(from url: URL) throws -> [EvalCase] {
        let decoder = JSONDecoder()
        let name = url.deletingPathExtension().lastPathComponent
        var cases: [EvalCase] = []
        for (index, line) in try String(contentsOf: url, encoding: .utf8).split(separator: "\n").enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            do {
                var evalCase = try decoder.decode(EvalCase.self, from: Data(trimmed.utf8))
                if evalCase.id.isEmpty { evalCase.id = "\(name):\(index + 1)" }
                cases.append(evalCase)
            } catch {
                throw TrainingData.Failure.unreadableLine(file: url.lastPathComponent, line: index + 1, reason: error.localizedDescription)
            }
        }
        return cases
    }

    /// How an answer compares with this case.
    public func judge(shown: String, fellBack: Bool, input: String, level: CleanupLevel) -> Verdict {
        let expected = ([target] + alternatives).filter { !$0.isEmpty }
        if expected.contains(where: { Self.sameText($0, shown, layout: multiline) }) { return .right }
        if fellBack { return .fellBack }
        let normalized = EditDistance.normalize(shown)
        if EditDistance.normalize(input) == normalized { return .unchanged }
        let missing = keep.first { !Self.contains(normalized, EditDistance.normalize($0)) }
        let added = avoid.first { Self.contains(normalized, EditDistance.normalize($0)) }
        if missing != nil || added != nil { return .changedMeaning }
        return .different
    }

    public enum Verdict: String, Codable, Sendable, CaseIterable {
        /// The shown text is the target, or an alternative.
        case right
        /// The output guard rejected the answer, so the text before cleanup was shown.
        case fellBack
        /// An accepted answer that left the words as they were (casing and punctuation aside).
        case unchanged
        /// An accepted answer that changed the words and lost a fact the case keeps, or has one it
        /// avoids.
        case changedMeaning
        /// Some other accepted answer, to be read by a person.
        case different
    }

    /// Same words, ignoring casing and punctuation; for a case that is laid out, also the same
    /// lines.
    static func sameText(_ lhs: String, _ rhs: String, layout: Bool) -> Bool {
        guard EditDistance.normalize(lhs) == EditDistance.normalize(rhs) else { return false }
        guard layout else { return true }
        func lines(_ text: String) -> [String] {
            text.split(whereSeparator: \.isNewline).map { EditDistance.normalize(String($0)) }.filter { !$0.isEmpty }
        }
        return lines(lhs) == lines(rhs)
    }

    private static func contains(_ text: String, _ phrase: String) -> Bool {
        guard !phrase.isEmpty else { return true }
        return " \(text) ".contains(" \(phrase) ")
    }
}
