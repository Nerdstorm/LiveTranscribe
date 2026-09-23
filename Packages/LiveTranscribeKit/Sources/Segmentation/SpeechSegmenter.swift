import Foundation
import Shared

/// Splits a continuous 16 kHz sample stream into speech segments.
///
/// Push-based: the session feeds captured buffers to `process(_:)` and acts on the returned
/// events; `flush()` closes any open segment when capture stops.
public protocol SpeechSegmenter: Actor {
    func load(progress: @escaping ModelLoadProgressHandler) async throws
    /// Starts a new timeline at 0 ms and forgets any open segment.
    func reset() async
    func process(_ samples: [Float]) async throws -> [SegmentationEvent]
    func flush() async -> [SegmentationEvent]
}

public enum SegmentCloseReason: String, Sendable, Codable, Equatable {
    /// Speech was followed by the configured amount of silence.
    case silence
    /// The segment reached the maximum length while speech continued.
    case maxLength
    /// Capture stopped while speech was in progress.
    case endOfStream
}

/// Audio of a segment, with its position on the session timeline.
public struct SpeechAudio: Sendable, Equatable {
    public let segmentID: UUID
    public let startMs: Int
    public let endMs: Int
    public let samples: [Float]
    /// Silence observed after the last speech before the segment closed. Zero while open.
    public let trailingSilenceMs: Int

    public init(segmentID: UUID, startMs: Int, endMs: Int, samples: [Float], trailingSilenceMs: Int) {
        self.segmentID = segmentID
        self.startMs = startMs
        self.endMs = endMs
        self.samples = samples
        self.trailingSilenceMs = trailingSilenceMs
    }
}

public enum SegmentationEvent: Sendable, Equatable {
    case speechStarted(segmentID: UUID, startMs: Int)
    /// A snapshot of an open segment, for optional live (partial) transcription.
    case partial(SpeechAudio)
    case closed(SpeechAudio, reason: SegmentCloseReason)
    /// The segment contained too little speech to transcribe (a click, a cough).
    case discarded(segmentID: UUID)
}

public enum SegmentationError: LocalizedError, Equatable {
    case modelNotLoaded
    case invalidModelID(String)

    public var errorDescription: String? {
        switch self {
        case .modelNotLoaded: "The voice activity model is not loaded."
        case .invalidModelID(let id): "Invalid voice activity model id: \(id)"
        }
    }
}
