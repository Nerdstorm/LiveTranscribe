import Foundation
import Persistence
import Shared
import Testing

@Suite("JSONLSessionSink")
struct JSONLSessionSinkTests {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("LiveTranscribeTests-\(UUID().uuidString)")
    }

    private func record(_ text: String, cleaned: String?, sessionID: UUID, fellBack: Bool = false) -> SegmentRecord {
        let segment = Segment(id: UUID(), sessionID: sessionID, startMs: 1_000, endMs: 2_500, rawText: text)
        let cleanedSegment = cleaned.map {
            CleanedSegment(segment: segment, cleanedText: $0, fellBack: fellBack, fallbackReason: fellBack ? "timed out after 3.0s" : nil, latencyMs: 420)
        }
        return SegmentRecord(
            segment: segment,
            cleaned: cleanedSegment,
            latency: StageLatencies(vadMs: 608, sttMs: 95, llmMs: cleaned == nil ? nil : 420, totalMs: 1_140),
            recordedAt: Date(timeIntervalSince1970: 1_790_000_000)
        )
    }

    @Test func recordsRoundTripThroughTheFile() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionID = UUID()
        let sink = try JSONLSessionSink(directory: directory, sessionID: sessionID)
        let first = record("i think so", cleaned: "I think so.", sessionID: sessionID)
        let second = record("raw only", cleaned: nil, sessionID: sessionID)
        let third = record("fell back", cleaned: "fell back", sessionID: sessionID, fellBack: true)

        try await sink.append(first)
        try await sink.append(second)
        try await sink.append(third)
        try await sink.close()

        let url = try #require(sink.location)
        #expect(url.lastPathComponent == "\(sessionID.uuidString).jsonl")
        #expect(try JSONLSessionSink.readRecords(at: url) == [first, second, third])
    }

    @Test func eachAppendIsOnDiskBeforeClose() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionID = UUID()
        let sink = try JSONLSessionSink(directory: directory, sessionID: sessionID)
        let url = try #require(sink.location)

        try await sink.append(record("one", cleaned: "One.", sessionID: sessionID))
        #expect(try JSONLSessionSink.readRecords(at: url).count == 1)
        try await sink.append(record("two", cleaned: "Two.", sessionID: sessionID))
        #expect(try JSONLSessionSink.readRecords(at: url).count == 2)
        try await sink.close()
    }

    @Test func oneJSONObjectPerLineWithTheDocumentedFields() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionID = UUID()
        let sink = try JSONLSessionSink(directory: directory, sessionID: sessionID)
        try await sink.append(record("hello", cleaned: "Hello.", sessionID: sessionID))
        try await sink.close()

        let text = try String(contentsOf: try #require(sink.location), encoding: .utf8)
        let lines = text.split(separator: "\n")
        #expect(lines.count == 1)
        let object = try #require(JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        for key in ["id", "sessionID", "startMs", "endMs", "rawText", "cleanedText", "fellBack", "latency", "recordedAt"] {
            #expect(object[key] != nil, "missing \(key)")
        }
        let latency = try #require(object["latency"] as? [String: Any])
        #expect(Set(latency.keys) == ["vadMs", "sttMs", "llmMs", "totalMs"])
    }

    @Test func appendAfterCloseThrows() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionID = UUID()
        let sink = try JSONLSessionSink(directory: directory, sessionID: sessionID)
        try await sink.close()
        await #expect(throws: PersistenceError.closed) {
            try await sink.append(record("late", cleaned: nil, sessionID: sessionID))
        }
    }
}
