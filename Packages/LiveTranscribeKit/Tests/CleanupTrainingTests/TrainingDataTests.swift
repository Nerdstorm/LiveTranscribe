import Cleanup
@testable import CleanupTraining
import Foundation
import MLXLMCommon
import Testing

@Suite("Training data")
struct TrainingDataTests {
    private func temporaryFile(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appending(component: "TrainingDataTests-\(UUID().uuidString)")
            .appending(component: name)
    }

    @Test func jsonLinesRoundTrip() throws {
        let url = temporaryFile("examples.jsonl")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let examples = [
            TrainingExample(category: .correction, context: ["Earlier line."], raw: "cars sorry buses", target: "Buses.", source: "generated"),
            TrainingExample(category: .cleanup, raw: "the the build", target: "The build.", source: "generated"),
        ]
        try TrainingData.write(examples, to: url)
        #expect(try TrainingData.read(from: url) == examples)
    }

    @Test func handWrittenLinesDefaultTheirSourceAndContext() throws {
        let url = temporaryFile("curated-work.jsonl")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"category":"control","raw":"sorry i'm late","target":"Sorry I'm late."}"#.write(to: url, atomically: true, encoding: .utf8)
        let example = try #require(try TrainingData.read(from: url).first)
        #expect(example.source == "curated-work")
        #expect(example.context.isEmpty)
    }

    @Test func aBadLineIsReportedWithItsLineNumber() throws {
        let url = temporaryFile("broken.jsonl")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{\"category\":\"cleanup\",\"raw\":\"a\",\"target\":\"A.\"}\n{\"category\":\"nonsense\"}\n".write(to: url, atomically: true, encoding: .utf8)
        let error = #expect(throws: TrainingData.Failure.self) {
            try TrainingData.read(from: url)
        }
        #expect(error?.errorDescription?.hasPrefix("broken.jsonl:2:") == true)
    }

    @Test func tokenizedExamplesAreThePromptThenTheTargetThenEndOfTurn() throws {
        let tokenizer = WordTokenizer()
        let example = TrainingExample(category: .correction, context: ["Earlier."], raw: "cars sorry buses", target: "buses", source: "test")
        let tokenized = try TrainingText.tokenize(example, template: Prompt.adapted, contextLimit: 3, tokenizer: tokenizer)

        let request = Prompt.request(for: example.raw, context: example.context, contextLimit: 3, template: Prompt.adapted)
        let prompt = try tokenizer.applyChatTemplate(
            messages: request.messages.map { ["role": $0.role.rawValue, "content": $0.content] },
            tools: nil,
            additionalContext: nil
        )
        #expect(tokenized.promptLength == prompt.count)
        #expect(Array(tokenized.tokens.prefix(prompt.count)) == prompt)
        #expect(Array(tokenized.tokens.dropFirst(prompt.count)) == tokenizer.encode(text: "buses", addSpecialTokens: false) + [WordTokenizer.endOfTurn])
    }

    @Test func batchesMaskEverythingButTheAnswer() {
        // Prompt of 3 tokens, answer of 2 (the last being end-of-turn); a shorter second row.
        let batch = PaddedBatch([
            TokenizedExample(tokens: [10, 11, 12, 20, 21], promptLength: 3),
            TokenizedExample(tokens: [30, 31, 40], promptLength: 2),
        ])
        #expect(batch.rows == 2)
        #expect(batch.width == 4)
        #expect(batch.inputs == [10, 11, 12, 20, 30, 31, 0, 0])
        #expect(batch.targets == [11, 12, 20, 21, 31, 40, 0, 0])
        #expect(batch.mask == [0, 0, 1, 1, 0, 1, 0, 0])
    }
}

/// Splits on spaces and gives every new word the next id; the chat "template" is each
/// message's role and content in turn.
private final class WordTokenizer: MLXLMCommon.Tokenizer, @unchecked Sendable {
    static let endOfTurn = 1

    private var ids = ["<|im_end|>": endOfTurn]

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        text.split(separator: " ").map { word in
            if let id = ids[String(word)] { return id }
            let id = ids.count + 1
            ids[String(word)] = id
            return id
        }
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        tokenIds.compactMap(convertIdToToken).joined(separator: " ")
    }

    func convertTokenToId(_ token: String) -> Int? { ids[token] }

    func convertIdToToken(_ id: Int) -> String? { ids.first { $0.value == id }?.key }

    var bosToken: String? { nil }
    var eosToken: String? { "<|im_end|>" }
    var unknownToken: String? { nil }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        messages.flatMap { message in
            encode(text: "\(message["role"] as? String ?? "") \(message["content"] as? String ?? "")", addSpecialTokens: false)
        }
    }
}
