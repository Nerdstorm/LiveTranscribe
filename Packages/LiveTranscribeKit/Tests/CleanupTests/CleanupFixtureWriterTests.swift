@testable import Cleanup
import Foundation
import Shared
import Testing

/// The parity fixtures for the Linux and Windows port of this module (linux-windows/crates/cleanup):
/// what this implementation asks the model, what the output guard decides, and what the executor
/// does with a scripted model. The port's tests read the same files and must match them exactly,
/// so both apps clean up text the same way.
///
/// These tests check the files in Fixtures/cleanup on every run. After an intended change to
/// cleanup, regenerate them, review the diff and port the change (see Fixtures/cleanup/README.md):
///
///     TEST_RUNNER_LT_WRITE_CLEANUP_FIXTURES=1 xcodebuild test … -only-testing:CleanupTests/CleanupFixtureWriterTests
@Suite("Cleanup fixtures")
struct CleanupFixtureWriterTests {
    /// The repository's Fixtures/cleanup, found from this file's path.
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // CleanupTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // LiveTranscribeKit
        .deletingLastPathComponent() // Packages
        .deletingLastPathComponent() // the repository
        .appendingPathComponent("Fixtures/cleanup", isDirectory: true)

    private static var writing: Bool {
        ProcessInfo.processInfo.environment["LT_WRITE_CLEANUP_FIXTURES"] == "1"
    }

    @Test func thePromptsMatchTheFixtures() throws {
        try Self.check(CleanupFixtures.Prompts.lines(), file: "prompts.jsonl")
    }

    @Test func theGuardPolicyMatchesTheFixture() throws {
        try Self.check([CleanupFixtures.Guard.defaultPolicyLine()], file: "guard-policy.json")
    }

    @Test func theGuardVerdictsMatchTheFixtures() throws {
        try Self.check(CleanupFixtures.Guard.lines(), file: "guard.jsonl")
    }

    @Test(.timeLimit(.minutes(1)))
    func theExecutorTracesMatchTheFixtures() async throws {
        try Self.check(await CleanupFixtures.Executor.lines(), file: "executor.jsonl")
    }

    /// Writes `produced` to `file` when writing fixtures, and otherwise expects the file to hold it.
    private static func check(_ produced: [String], file name: String) throws {
        let file = directory.appendingPathComponent(name)
        if writing {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try (produced.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
            return
        }
        let recorded = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(recorded.count == produced.count, "\(name) has one line per case; regenerate after changing the cases")
        let differing = zip(recorded, produced).filter { $0 != $1 }
        for (was, now) in differing.prefix(3) {
            Issue.record("\(name) changed:\n  recorded: \(was)\n  produced: \(now)")
        }
        #expect(differing.isEmpty, "\(differing.count) cases in \(name) changed; if intended, regenerate and review the diff")
    }
}

/// What the fixtures hold, as JSON.
enum CleanupFixtures {
    /// One fixture line: sorted keys and unescaped slashes, so regenerating an unchanged case
    /// writes the same bytes.
    static func line(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    /// A Double as Swift writes it: the shortest text that reads back as the same value, so the
    /// port compares it exactly rather than through a JSON number.
    static func number(_ value: Double) -> String {
        "\(value)"
    }

    struct Options: Encodable {
        let level: String
        let vocabulary: [String]
        let placeholders: [String]

        init(_ options: CleanupOptions) {
            level = options.level.rawValue
            vocabulary = options.vocabulary
            placeholders = options.placeholders
        }
    }

    struct Message: Encodable {
        let role: String
        let content: String
    }

    /// A request as the model gets it.
    struct Request: Encodable {
        let messages: [Message]
        let templateContext: [String: Bool]
        let maxTokens: Int
        /// Whether MLXCleaner switches the adapter on for the request: at the levels that resolve
        /// self-corrections, for both of High's passes, and for the warm-up.
        let adapter: Bool

        init(_ request: CleanupRequest, adapter: Bool) {
            messages = request.messages.map { Message(role: $0.role.rawValue, content: $0.content) }
            templateContext = request.templateContext
            maxTokens = request.maxTokens
            self.adapter = adapter
        }
    }

    struct Template: Encodable {
        struct Example: Encodable {
            let text: String
            let cleaned: String
        }

        let system: String
        let examples: [Example]

        init(_ template: PromptTemplate) {
            system = template.system
            examples = template.examples.map { Example(text: $0.text, cleaned: $0.cleaned) }
        }
    }

    /// A fallback reason: its case, its value (a text, a count or a number) and its description.
    struct Reason: Encodable {
        let reason: String
        var text: String?
        var count: Int?
        var number: String?
        let description: String

        init(_ fallback: FallbackReason) {
            description = fallback.description
            switch fallback {
            case .emptyOutput: reason = "emptyOutput"
            case .thinkingLeaked: reason = "thinkingLeaked"
            case .preamble(let phrase): reason = "preamble"; text = phrase
            case .wordRatio(let ratio): reason = "wordRatio"; number = CleanupFixtures.number(ratio)
            case .lowSimilarity(let similarity): reason = "lowSimilarity"; number = CleanupFixtures.number(similarity)
            case .invalidSelfCorrection: reason = "invalidSelfCorrection"
            case .selfCorrectionNotAllowed: reason = "selfCorrectionNotAllowed"
            case .placeholderChanged: reason = "placeholderChanged"
            case .droppedWords(let dropped): reason = "droppedWords"; count = dropped
            case .lostNegation: reason = "lostNegation"
            case .movedOrDroppedName: reason = "movedOrDroppedName"
            case .droppedContent(let dropped): reason = "droppedContent"; count = dropped
            case .timedOut(let seconds): reason = "timedOut"; number = CleanupFixtures.number(seconds)
            case .cancelled: reason = "cancelled"
            case .generationFailed(let message): reason = "generationFailed"; text = message
            }
        }
    }
}
