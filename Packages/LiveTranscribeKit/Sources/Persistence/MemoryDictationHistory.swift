import Foundation

/// A ``DictationHistory`` that keeps records in memory, for tests, previews and fakes.
///
/// Behaves like ``JSONLDictationHistory`` (ordering, delete and prune rules, millisecond
/// `createdAt`), and it can be told to fail so callers can test their error paths.
public actor MemoryDictationHistory: DictationHistory {
    /// Records in the order they were appended, oldest first.
    public private(set) var records: [DictationRecord]
    private var failure: DictationHistoryError?

    /// - Parameter records: Initial history in append order, oldest first.
    public init(records: [DictationRecord] = []) {
        self.records = records
    }

    /// Makes every operation throw `error` until it is set back to `nil`.
    public func setFailure(_ error: DictationHistoryError?) {
        failure = error
    }

    public func append(_ record: DictationRecord) throws {
        try throwIfFailing()
        records.append(record)
    }

    public func recent(limit: Int) throws -> [DictationRecord] {
        try throwIfFailing()
        guard limit > 0 else { return [] }
        return Array(records.suffix(limit).reversed())
    }

    public func all() throws -> [DictationRecord] {
        try throwIfFailing()
        return records.reversed()
    }

    public func delete(id: UUID) throws {
        try throwIfFailing()
        records.removeAll { $0.id == id }
    }

    public func prune(olderThan cutoff: Date) throws -> Int {
        try throwIfFailing()
        let before = records.count
        records.removeAll { $0.isPruned(olderThan: cutoff) }
        return before - records.count
    }

    public func clear() throws {
        try throwIfFailing()
        records.removeAll()
    }

    private func throwIfFailing() throws {
        if let failure { throw failure }
    }
}
