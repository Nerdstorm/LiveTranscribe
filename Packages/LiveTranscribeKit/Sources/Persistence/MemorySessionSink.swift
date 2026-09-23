import Foundation

/// A ``SessionSink`` that keeps records in memory. Used by the bench and tests.
public actor MemorySessionSink: SessionSink {
    public nonisolated let location: URL? = nil
    public private(set) var records: [SegmentRecord] = []
    public private(set) var isClosed = false

    public init() {}

    public func append(_ record: SegmentRecord) throws {
        guard !isClosed else { throw PersistenceError.closed }
        records.append(record)
    }

    public func close() {
        isClosed = true
    }
}
