@testable import Dictation
import Foundation
import Shared
import Snippets
@testable import SpokenCommands
import Testing
import Vocabulary

/// The shared golden cases for dictation's text path without the language model: snippets,
/// spoken commands, vocabulary, filler removal, list and letter layout, and numbers.
///
/// Fixtures/golden/dictation-text.jsonl records what this implementation makes of every
/// transcript in dictation-inputs.txt, at each cleanup level, in single-line and multi-line
/// fields, and emoji-names.tsv every name an emoji command accepts. The Linux and Windows app
/// (linux-windows/) checks its port of these rules against the same files, so the two apps type
/// the same text. After an intended change to the rules, regenerate the files and review their
/// diff (see Fixtures/golden/README.md):
///
///     make golden
@Suite("Golden dictation fixtures")
struct GoldenDictationFixtureTests {
    /// The repository's Fixtures/golden, found from this file's path.
    private static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // DictationTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // LiveTranscribeKit
        .deletingLastPathComponent() // Packages
        .deletingLastPathComponent() // the repository
        .appendingPathComponent("Fixtures/golden", isDirectory: true)

    private static var updating: Bool {
        ProcessInfo.processInfo.environment["LT_UPDATE_GOLDEN"] == "1"
    }

    @Test func theTextPathMatchesTheGoldenCases() async throws {
        let settings = try GoldenSettings.load(from: Self.directory.appendingPathComponent("dictation-settings.json"))
        let transcripts = try String(contentsOf: Self.directory.appendingPathComponent("dictation-inputs.txt"), encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.hasPrefix("#") }
        #expect(transcripts.count > 1_000, "the inputs file was read")

        var produced: [String] = []
        for transcript in transcripts {
            var expected: [String: [String: GoldenOutput]] = [:]
            for level in CleanupLevel.allCases {
                for multiline in [false, true] {
                    let output = await DictationProcessor.finish(
                        transcript: transcript,
                        transcriptionMs: 0,
                        configuration: settings.configuration(level: level, multiline: multiline),
                        cleaner: nil
                    )
                    expected[level.rawValue, default: [:]][multiline ? "multiline" : "singleLine"] = GoldenOutput(
                        uncleaned: output.uncleanedText,
                        text: output.text,
                        fellBack: output.fellBack
                    )
                }
            }
            produced.append(try GoldenLine.encode(transcript: transcript, expected: expected))
        }
        try Self.check(produced, file: "dictation-text.jsonl", cases: "golden cases")
    }

    /// Every name an emoji command accepts before its plural rule ("hearts" → "heart"), with the
    /// emoji it inserts: the common names, and each emoji's Unicode name that this system
    /// resolves. The Rust port reads this table instead of its own Unicode data, whose version
    /// and name matching differ from the system's.
    @Test func theEmojiNamesMatchTheGoldenTable() throws {
        var table = EmojiNames.commonNames
        for value in UInt32(0)...0x10FFFF {
            // Only an emoji's name can name an emoji.
            guard let scalar = Unicode.Scalar(value), scalar.properties.isEmoji || scalar.properties.isEmojiPresentation,
                  let name = scalar.properties.name?.lowercased(), table[name] == nil,
                  let emoji = EmojiNames.emoji(unicodeName: name)
            else { continue }
            table[name] = emoji
        }
        #expect(table.count > 1_500, "the common names and the Unicode names are there")

        let header = [
            "# Every name an emoji command accepts, before the plural rule, and the emoji it inserts, from",
            "# the Mac app's EmojiNames: its common names, then each emoji's Unicode name that macOS resolves.",
            "# Columns: name, the emoji's scalars in hex, the emoji. Written by make golden; do not edit.",
        ]
        let rows = table.sorted { $0.key < $1.key }.map { name, emoji in
            let scalars = emoji.unicodeScalars.map { String(format: "%04X", $0.value) }.joined(separator: " ")
            return "\(name)\t\(scalars)\t\(emoji)"
        }
        try Self.check(header + rows, file: "emoji-names.tsv", cases: "emoji names")
    }

    /// Writes `produced` to `file` when updating, and otherwise expects the file to hold it.
    private static func check(_ produced: [String], file name: String, cases: String) throws {
        let file = directory.appendingPathComponent(name)
        if updating {
            try (produced.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
            return
        }
        let recorded = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(recorded.count == produced.count, "\(name) has one line per case; regenerate after changing the inputs")
        let differing = zip(recorded, produced).filter { $0 != $1 }
        for (was, now) in differing.prefix(5) {
            Issue.record("\(name) changed:\n  recorded: \(was)\n  produced: \(now)")
        }
        #expect(differing.isEmpty, "\(differing.count) \(cases) changed; if intended, run make golden and review the diff")
    }
}

/// The snippets, vocabulary and prompt limits every golden case runs with.
private struct GoldenSettings: Decodable {
    struct SnippetSetting: Decodable {
        let trigger: String
        let expansion: String
    }

    struct VocabularySetting: Decodable {
        let term: String
        let spokenVariants: [String]
    }

    let snippets: [SnippetSetting]
    let vocabulary: [VocabularySetting]
    let vocabularyPromptLimit: Int
    let vocabularySimilarityThreshold: Double

    static func load(from url: URL) throws -> GoldenSettings {
        try JSONDecoder().decode(GoldenSettings.self, from: Data(contentsOf: url))
    }

    func configuration(level: CleanupLevel, multiline: Bool) -> DictationProcessor.Configuration {
        DictationProcessor.Configuration(
            level: level,
            snippets: snippets.map { Snippet(trigger: $0.trigger, expansion: $0.expansion) },
            vocabulary: vocabulary.map { VocabularyEntry(term: $0.term, spokenVariants: $0.spokenVariants) },
            vocabularyPromptLimit: vocabularyPromptLimit,
            vocabularySimilarityThreshold: vocabularySimilarityThreshold,
            multiline: multiline
        )
    }
}

private struct GoldenOutput: Encodable, Equatable {
    /// What Undo AI edit puts back.
    let uncleaned: String
    /// What dictation types.
    let text: String
    let fellBack: Bool
}

/// One line of dictation-text.jsonl: the transcript first so a diff reads well, then the outputs
/// with sorted keys so regenerating an unchanged case writes the same bytes.
private enum GoldenLine {
    static func encode(transcript: String, expected: [String: [String: GoldenOutput]]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let transcriptJSON = try String(decoding: encoder.encode(transcript), as: UTF8.self)
        let expectedJSON = try String(decoding: encoder.encode(expected), as: UTF8.self)
        return "{\"transcript\":\(transcriptJSON),\"expected\":\(expectedJSON)}"
    }
}
