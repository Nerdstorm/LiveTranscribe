@testable import Dictation
import Foundation
import Shared
import Testing

/// The ways people ask for an emoji, and what dictation makes of each, in
/// Fixtures/golden/emoji-phrasing.tsv: "emoji fireworks" and "the fire emoji is my favourite" on
/// the one hand, "insert a fireworks emoji" and "smiley face" on the other.
///
/// A row marked `works` must make the text the speaker wants; a row marked `gap` must not yet,
/// so the day a rule change closes a gap this test says so and the row is set to `works`. The
/// matcher stays conservative on purpose (a phrase talked about stays as said), so the gaps are
/// phrasings to decide about. The Rust port runs the same rows.
@Suite("Emoji phrasing fixtures")
struct EmojiPhrasingFixtureTests {
    private static let golden = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // DictationTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // LiveTranscribeKit
        .deletingLastPathComponent() // Packages
        .deletingLastPathComponent() // the repository
        .appendingPathComponent("Fixtures/golden", isDirectory: true)

    @Test func everyPhrasingDoesWhatItsStatusSays() async throws {
        let rows = try String(contentsOf: Self.golden.appendingPathComponent("emoji-phrasing.tsv"), encoding: .utf8)
            .split(separator: "\n")
            .filter { !$0.hasPrefix("#") }
            .dropFirst() // the header
            .map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
        #expect(rows.count >= 100, "the rows were read")

        var wrong: [String] = []
        for row in rows {
            #expect(row.count == 6, "\(row.first ?? "?"): six columns")
            guard row.count == 6 else { continue }
            let (id, spoken, expected, intent, status) = (row[0], row[1], row[2], row[3], row[5])
            let output = await DictationProcessor.finish(
                transcript: spoken,
                transcriptionMs: 0,
                configuration: DictationProcessor.Configuration(
                    level: .none, snippets: [], vocabulary: [], vocabularyPromptLimit: 10,
                    vocabularySimilarityThreshold: 0.8, multiline: false
                ),
                cleaner: nil
            )
            if intent == "keep", expected != spoken { wrong.append("\(id): a keep row wants its words as said") }
            if (output.text == expected) != (status == "works") {
                wrong.append("\(id) is marked \(status), but dictation made \(output.text.debugDescription) of \(spoken.debugDescription)")
            }
        }
        #expect(wrong.isEmpty, "\(wrong.joined(separator: "\n"))")
    }
}
