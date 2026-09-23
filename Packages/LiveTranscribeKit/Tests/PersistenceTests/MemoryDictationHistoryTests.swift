import Foundation
import Persistence
import Testing

/// What the in-memory fake adds for callers' tests: seeding and forced failures.
@Suite("MemoryDictationHistory")
struct MemoryDictationHistoryTests {
    @Test func startsFromTheGivenRecordsInAppendOrder() async throws {
        let older = DictationHistoryFixtures.record("older", offsetMs: 0)
        let newer = DictationHistoryFixtures.record("newer", offsetMs: 1)
        let history = MemoryDictationHistory(records: [older, newer])

        #expect(try await history.all() == [newer, older])
        #expect(await history.records == [older, newer])
    }

    @Test func everyOperationThrowsWhileAFailureIsSet() async throws {
        let failure = DictationHistoryError.writeFailed("disk full")
        let history = MemoryDictationHistory()
        await history.setFailure(failure)

        await #expect(throws: failure) { try await history.append(DictationHistoryFixtures.record("lost", offsetMs: 0)) }
        await #expect(throws: failure) { try await history.recent(limit: 1) }
        await #expect(throws: failure) { try await history.all() }
        await #expect(throws: failure) { try await history.delete(id: UUID()) }
        await #expect(throws: failure) { try await history.prune(olderThan: .now) }
        await #expect(throws: failure) { try await history.clear() }

        await history.setFailure(nil)
        let record = DictationHistoryFixtures.record("kept", offsetMs: 0)
        try await history.append(record)
        #expect(try await history.all() == [record])
    }

    @Test func errorsReadAsSentences() {
        let errors: [DictationHistoryError] = [
            .directoryUnavailable("no space"), .writeFailed("no space"), .readFailed("no space"), .rewriteFailed("no space"),
        ]
        for error in errors {
            let description = error.errorDescription ?? ""
            #expect(description.hasSuffix("no space"))
            #expect(description.first?.isUppercase == true)
        }
    }
}
