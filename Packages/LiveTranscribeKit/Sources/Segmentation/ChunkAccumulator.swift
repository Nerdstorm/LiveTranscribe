/// Regroups arbitrarily sized sample buffers into fixed-size chunks.
public struct ChunkAccumulator: Sendable {
    public let chunkSize: Int
    private var pending: [Float] = []

    public init(chunkSize: Int) {
        precondition(chunkSize > 0, "chunkSize must be positive")
        self.chunkSize = chunkSize
    }

    /// Samples waiting for enough company to form a chunk.
    public var pendingCount: Int { pending.count }

    /// Appends samples and returns every complete chunk now available, in order.
    public mutating func append(_ samples: [Float]) -> [[Float]] {
        pending.append(contentsOf: samples)
        let chunkCount = pending.count / chunkSize
        guard chunkCount > 0 else { return [] }

        var chunks: [[Float]] = []
        chunks.reserveCapacity(chunkCount)
        for index in 0..<chunkCount {
            let start = index * chunkSize
            chunks.append(Array(pending[start..<(start + chunkSize)]))
        }
        pending.removeFirst(chunkCount * chunkSize)
        return chunks
    }

    public mutating func reset() {
        pending.removeAll(keepingCapacity: true)
    }
}
