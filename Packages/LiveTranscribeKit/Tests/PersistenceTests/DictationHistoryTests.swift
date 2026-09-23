import Foundation
import Persistence
import Testing

/// Behaviour every ``DictationHistory`` shares, run against each implementation.
@Suite("DictationHistory")
struct DictationHistoryTests {
    private typealias Fixtures = DictationHistoryFixtures

    @Test(arguments: HistoryBackend.allCases)
    func readsNewestFirst(backend: HistoryBackend) async throws {
        let subject = backend.make()
        defer { subject.cleanUp() }
        let first = Fixtures.record("first", offsetMs: 0)
        let second = Fixtures.record("second", offsetMs: 1_000)
        let third = Fixtures.record("third", offsetMs: 2_000)

        for record in [first, second, third] {
            try await subject.history.append(record)
        }

        #expect(try await subject.history.all() == [third, second, first])
    }

    @Test(arguments: HistoryBackend.allCases, [(-1, 0), (0, 0), (1, 1), (2, 2), (3, 3), (10, 3)])
    func recentReturnsAtMostTheLimitNewestFirst(backend: HistoryBackend, limitAndCount: (Int, Int)) async throws {
        let subject = backend.make()
        defer { subject.cleanUp() }
        for index in 0..<3 {
            try await subject.history.append(Fixtures.record("dictation \(index)", offsetMs: index * 1_000))
        }

        let recent = try await subject.history.recent(limit: limitAndCount.0)
        let all = try await subject.history.all()

        #expect(recent == Array(all.prefix(limitAndCount.1)))
    }

    @Test(arguments: HistoryBackend.allCases)
    func anEmptyHistoryHasNothingToReadOrRemove(backend: HistoryBackend) async throws {
        let subject = backend.make()
        defer { subject.cleanUp() }

        #expect(try await subject.history.all().isEmpty)
        #expect(try await subject.history.recent(limit: 5).isEmpty)
        #expect(try await subject.history.prune(olderThan: Fixtures.baseDate) == 0)
        try await subject.history.delete(id: UUID())
        try await subject.history.clear()
        #expect(try await subject.history.all().isEmpty)
    }

    @Test(arguments: HistoryBackend.allCases)
    func deleteRemovesOnlyThatRecord(backend: HistoryBackend) async throws {
        let subject = backend.make()
        defer { subject.cleanUp() }
        let keep = Fixtures.record("keep", offsetMs: 0)
        let remove = Fixtures.record("remove", offsetMs: 1_000)
        let alsoKeep = Fixtures.record("also keep", offsetMs: 2_000)
        for record in [keep, remove, alsoKeep] {
            try await subject.history.append(record)
        }

        try await subject.history.delete(id: remove.id)

        #expect(try await subject.history.all() == [alsoKeep, keep])
    }

    @Test(arguments: HistoryBackend.allCases)
    func deletingAnUnknownIDChangesNothing(backend: HistoryBackend) async throws {
        let subject = backend.make()
        defer { subject.cleanUp() }
        let record = Fixtures.record("only", offsetMs: 0)
        try await subject.history.append(record)

        try await subject.history.delete(id: UUID())

        #expect(try await subject.history.all() == [record])
    }

    /// The boundary is inclusive: a record created exactly at the cutoff is kept, so "keep 30
    /// days" keeps the dictation made exactly 30 days ago.
    @Test(arguments: HistoryBackend.allCases)
    func pruneRemovesOnlyRecordsBeforeTheCutoff(backend: HistoryBackend) async throws {
        let subject = backend.make()
        defer { subject.cleanUp() }
        let cutoff = Fixtures.baseDate.addingTimeInterval(10)
        let wellBefore = Fixtures.record("well before", offsetMs: 0)
        let justBefore = Fixtures.record("just before", offsetMs: 9_999)
        let atCutoff = Fixtures.record("at the cutoff", offsetMs: 10_000)
        let after = Fixtures.record("after", offsetMs: 10_001)
        for record in [wellBefore, justBefore, atCutoff, after] {
            try await subject.history.append(record)
        }

        let removed = try await subject.history.prune(olderThan: cutoff)

        #expect(removed == 2)
        #expect(try await subject.history.all() == [after, atCutoff])
    }

    /// Records keep `createdAt` to the millisecond, so every backend compares a sub-millisecond
    /// cutoff the same way: a record made at the cutoff itself is kept.
    @Test(arguments: HistoryBackend.allCases)
    func aSubMillisecondCutoffPrunesTheSameOnEveryBackend(backend: HistoryBackend) async throws {
        let subject = backend.make()
        defer { subject.cleanUp() }
        let cutoff = Fixtures.baseDate.addingTimeInterval(10.0004)
        let justBefore = Fixtures.record("just before", offsetMs: 9_999)
        let atCutoff = Fixtures.record("made at the cutoff", createdAt: cutoff)
        let sameMillisecond = Fixtures.record("same millisecond", createdAt: Fixtures.baseDate.addingTimeInterval(9.9996))
        for record in [justBefore, sameMillisecond, atCutoff] {
            try await subject.history.append(record)
        }

        #expect(try await subject.history.prune(olderThan: cutoff) == 1)
        #expect(try await subject.history.all() == [atCutoff, sameMillisecond])
    }

    /// A cutoff that is not a real date must never be read as "remove everything".
    @Test(arguments: HistoryBackend.allCases)
    func anInvalidCutoffRemovesNothing(backend: HistoryBackend) async throws {
        let subject = backend.make()
        defer { subject.cleanUp() }
        let record = Fixtures.record("kept", offsetMs: 0)
        try await subject.history.append(record)

        #expect(try await subject.history.prune(olderThan: Date(timeIntervalSinceReferenceDate: .nan)) == 0)
        #expect(try await subject.history.all() == [record])
    }

    /// A record made from `Date()` has sub-millisecond precision; it reads back equal to the one
    /// appended on every backend.
    @Test(arguments: HistoryBackend.allCases)
    func aRecordReadsBackEqualToTheOneAppended(backend: HistoryBackend) async throws {
        let subject = backend.make()
        defer { subject.cleanUp() }
        let record = Fixtures.record("now", createdAt: Fixtures.baseDate.addingTimeInterval(0.987_654_321))

        try await subject.history.append(record)

        #expect(try await subject.history.all() == [record])
        #expect(try await subject.history.recent(limit: 1) == [record])
    }

    @Test(arguments: HistoryBackend.allCases)
    func pruneWithNothingOldKeepsEverything(backend: HistoryBackend) async throws {
        let subject = backend.make()
        defer { subject.cleanUp() }
        let records = (0..<3).map { Fixtures.record("recent \($0)", offsetMs: 60_000 + $0) }
        for record in records {
            try await subject.history.append(record)
        }

        #expect(try await subject.history.prune(olderThan: Fixtures.baseDate) == 0)
        #expect(try await subject.history.all() == records.reversed())
    }

    @Test(arguments: HistoryBackend.allCases)
    func clearRemovesEverythingAndHistoryCarriesOn(backend: HistoryBackend) async throws {
        let subject = backend.make()
        defer { subject.cleanUp() }
        for index in 0..<3 {
            try await subject.history.append(Fixtures.record("old \(index)", offsetMs: index))
        }

        try await subject.history.clear()
        #expect(try await subject.history.all().isEmpty)

        let next = Fixtures.record("after clearing", offsetMs: 5_000)
        try await subject.history.append(next)
        #expect(try await subject.history.all() == [next])
    }

    @Test(arguments: HistoryBackend.allCases)
    func concurrentAppendsKeepEveryRecord(backend: HistoryBackend) async throws {
        let subject = backend.make()
        defer { subject.cleanUp() }
        let history = subject.history
        let records = (0..<200).map { Fixtures.record("dictation number \($0)", offsetMs: $0) }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for record in records {
                group.addTask { try await history.append(record) }
            }
            try await group.waitForAll()
        }

        let stored = try await history.all()
        #expect(stored.count == records.count)
        #expect(Set(stored.map(\.id)) == Set(records.map(\.id)))
        #expect(stored.sorted { $0.createdAt < $1.createdAt } == records)
    }
}
