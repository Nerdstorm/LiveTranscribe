import Foundation

/// One speech segment as transcribed and the transcript line the app should show for it.
public struct TrainingExample: Codable, Sendable, Equatable {
    public enum Category: String, Codable, CodingKeyRepresentable, Sendable, CaseIterable {
        /// A spoken self-correction: the target drops the retracted words and the cue.
        case correction
        /// A correction cue used in its ordinary meaning ("sorry I'm late"): every word stays.
        case control
        /// No cue: only casing and punctuation change, and a doubled word may go.
        case cleanup
        /// A cue correcting the previous segment, which can no longer be edited: every word stays.
        case boundary
    }

    public var category: Category
    /// Earlier transcript lines, sent as read-only context as the app does.
    public var context: [String]
    public var raw: String
    public var target: String
    /// Where the example came from: "generated", or the curated file it was read from.
    public var source: String

    public init(category: Category, context: [String] = [], raw: String, target: String, source: String) {
        self.category = category
        self.context = context
        self.raw = raw
        self.target = target
        self.source = source
    }

    enum CodingKeys: String, CodingKey {
        case category, context, raw, target, source
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        category = try container.decode(Category.self, forKey: .category)
        context = try container.decodeIfPresent([String].self, forKey: .context) ?? []
        raw = try container.decode(String.self, forKey: .raw)
        target = try container.decode(String.self, forKey: .target)
        source = try container.decodeIfPresent(String.self, forKey: .source) ?? ""
    }
}

/// Reads and writes examples as JSON Lines, one example per line.
public enum TrainingData {
    public enum Failure: LocalizedError {
        case unreadableLine(file: String, line: Int, reason: String)

        public var errorDescription: String? {
            switch self {
            case .unreadableLine(let file, let line, let reason): "\(file):\(line): \(reason)"
            }
        }
    }

    /// Examples without a `source` get the file's name.
    public static func read(from url: URL) throws -> [TrainingExample] {
        let decoder = JSONDecoder()
        let name = url.deletingPathExtension().lastPathComponent
        var examples: [TrainingExample] = []
        for (index, line) in try String(contentsOf: url, encoding: .utf8).split(separator: "\n").enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            do {
                var example = try decoder.decode(TrainingExample.self, from: Data(trimmed.utf8))
                if example.source.isEmpty { example.source = name }
                examples.append(example)
            } catch {
                throw Failure.unreadableLine(file: url.lastPathComponent, line: index + 1, reason: error.localizedDescription)
            }
        }
        return examples
    }

    public static func write(_ examples: [TrainingExample], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var text = ""
        for example in examples {
            text += String(decoding: try encoder.encode(example), as: UTF8.self) + "\n"
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// A small, fast, seedable generator (SplitMix64), so generated data and shuffles are
/// reproducible.
public struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
