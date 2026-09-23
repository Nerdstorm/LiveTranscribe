import Foundation
import Shared

/// One persisted segment: raw text (always), cleaned text (when cleanup ran), and latencies.
public struct SegmentRecord: Sendable, Codable, Equatable {
    public let id: UUID
    public let sessionID: UUID
    public let startMs: Int
    public let endMs: Int
    public let rawText: String
    /// `nil` when cleanup was disabled or unavailable for this session.
    public let cleanedText: String?
    public let fellBack: Bool
    public let fallbackReason: String?
    public let latency: StageLatencies
    public let recordedAt: Date

    public init(segment: Segment, cleaned: CleanedSegment?, latency: StageLatencies, recordedAt: Date) {
        self.id = segment.id
        self.sessionID = segment.sessionID
        self.startMs = segment.startMs
        self.endMs = segment.endMs
        self.rawText = segment.rawText
        self.cleanedText = cleaned?.cleanedText
        self.fellBack = cleaned?.fellBack ?? false
        self.fallbackReason = cleaned?.fallbackReason
        self.latency = latency
        self.recordedAt = recordedAt
    }
}

/// Where a session's segments are written.
public protocol SessionSink: Actor {
    /// The file backing this sink, if it has one.
    nonisolated var location: URL? { get }
    func append(_ record: SegmentRecord) async throws
    /// Flushes and releases the sink. Appending afterwards throws.
    func close() async throws
}

public enum PersistenceError: LocalizedError, Equatable {
    case cannotCreateFile(String)
    case closed
    case directoryUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .cannotCreateFile(let path): "Could not create the session file at \(path)."
        case .closed: "The session file is already closed."
        case .directoryUnavailable(let detail): "The sessions folder is unavailable: \(detail)"
        }
    }
}
