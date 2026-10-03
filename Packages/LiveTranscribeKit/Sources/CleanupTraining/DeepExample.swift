import Foundation

/// One example for Deep's adapter: a dictation as speech recognition wrote it, and the text Deep
/// should show for it. Unlike ``TrainingExample`` it knows whether the field takes several lines,
/// which decides whether Deep may lay the text out.
///
/// Its JSON is also an ``EvalCase``'s, so `Train measure` can score the generated test split.
/// Placeholder tokens (`⟦S1⟧`) in the raw text are the ones the app passes with it.
public struct DeepExample: Codable, Sendable, Equatable {
    public enum Category: String, Codable, Sendable, CaseIterable {
        /// A correction that takes back words in an earlier sentence.
        case crossSentence = "cross-sentence"
        /// A correction whose phrase came out garbled ("the after tomorrow"), read as meant.
        case malformed
        /// A correction within one sentence, as Medium resolves it.
        case sameSentence = "same-sentence"
        /// A cue word in its ordinary meaning, which stays: an answer, an apology, a new point.
        case control
        /// Names, numbers, dates and negations, which stay as said.
        case facts
        /// A grammar mistake, fixed without rewording.
        case grammar
        /// A word the recognizer misheard, written as meant.
        case recognition
        /// An email, letter or list laid out in a field that takes several lines.
        case layout
        /// The same kind of text in a one-line field, which stays one paragraph.
        case oneLine = "one-line"
        /// Text that is already right.
        case unchanged
        // The categories below are the ones of `Training/eval/layout.jsonl`, so the generated test
        // split and the hand-written cases report in the same rows.
        /// Two things set off with a colon ("two things I need: A and B"): a list in a field that
        /// takes several lines, a sentence in one that takes one.
        case listTwo = "list-two"
        /// Three to six items, bulleted or numbered, with an opening sentence, a greeting or a
        /// closing sentence around them.
        case listMany = "list-many"
        /// A series said inside a sentence, or a colon that introduces no list, which stay as said
        /// in any field.
        case series
        /// The body of an email, whose greeting and sign-off the app lays out itself.
        case body = "email-body"
        /// Placeholder tokens (emoji, links, list markers), kept where they stand.
        case placeholder
        /// A correction said inside a mention ("words like X, sorry, not X, Y"), and an ordinary
        /// contrast ("three, not four") that stays.
        case mention
        /// Several dictations said one after another, each as its own category has it: the
        /// measured preparation joins them so the model reads longer text. Never generated, and
        /// last, so the generator's seeded output doesn't change.
        case composite
    }

    public var category: Category
    /// Earlier transcript lines, sent as read-only context as the app does.
    public var context: [String]
    public var raw: String
    public var target: String
    /// The field takes several lines.
    public var multiline: Bool
    /// The text is the body of an email: the app has laid out its greeting and sign-off.
    public var letterBody: Bool
    /// Where the example came from: "generated", or the file it was read from.
    public var source: String

    public init(
        category: Category,
        context: [String] = [],
        raw: String,
        target: String,
        multiline: Bool,
        letterBody: Bool = false,
        source: String
    ) {
        self.category = category
        self.context = context
        self.raw = raw
        self.target = target
        self.multiline = multiline
        self.letterBody = letterBody
        self.source = source
    }

    /// Medium's example as one of Deep's, whose target is the same: a correction resolved in its
    /// sentence, a cue kept, or text in which every word stays.
    public init(medium example: TrainingExample, multiline: Bool) {
        let category: Category = switch example.category {
        case .correction: .sameSentence
        case .control, .boundary: .control
        case .cleanup: .unchanged
        }
        self.init(
            category: category, context: example.context, raw: example.raw, target: example.target,
            multiline: multiline, source: "medium-\(example.source)"
        )
    }

    enum CodingKeys: String, CodingKey {
        case category, context, raw, target, multiline, letterBody, source
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        category = try container.decode(Category.self, forKey: .category)
        context = try container.decodeIfPresent([String].self, forKey: .context) ?? []
        raw = try container.decode(String.self, forKey: .raw)
        target = try container.decode(String.self, forKey: .target)
        multiline = try container.decodeIfPresent(Bool.self, forKey: .multiline) ?? false
        letterBody = try container.decodeIfPresent(Bool.self, forKey: .letterBody) ?? false
        source = try container.decodeIfPresent(String.self, forKey: .source) ?? ""
    }

    /// Reads JSON Lines of examples. Examples without a `source` get the file's name.
    public static func read(from url: URL) throws -> [DeepExample] {
        let decoder = JSONDecoder()
        let name = url.deletingPathExtension().lastPathComponent
        var examples: [DeepExample] = []
        for (index, line) in try String(contentsOf: url, encoding: .utf8).split(separator: "\n").enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            do {
                var example = try decoder.decode(DeepExample.self, from: Data(trimmed.utf8))
                if example.source.isEmpty { example.source = name }
                examples.append(example)
            } catch {
                throw TrainingData.Failure.unreadableLine(file: url.lastPathComponent, line: index + 1, reason: error.localizedDescription)
            }
        }
        return examples
    }

    public static func write(_ examples: [DeepExample], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let lines = try examples.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
