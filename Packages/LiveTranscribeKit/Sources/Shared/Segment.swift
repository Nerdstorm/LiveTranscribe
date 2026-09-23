import Foundation

/// A finalised utterance as produced by speech-to-text.
///
/// The raw transcript is the source of truth; cleaned text is a derived view (see ``CleanedSegment``).
public struct Segment: Sendable, Codable, Identifiable, Equatable {
    public let id: UUID
    public let sessionID: UUID
    /// Start of the segment's audio, in milliseconds since the session started.
    public let startMs: Int
    /// End of the segment's audio, in milliseconds since the session started.
    public let endMs: Int
    public let rawText: String

    public init(id: UUID, sessionID: UUID, startMs: Int, endMs: Int, rawText: String) {
        self.id = id
        self.sessionID = sessionID
        self.startMs = startMs
        self.endMs = endMs
        self.rawText = rawText
    }
}

/// The LLM-corrected view of a ``Segment``.
///
/// When the output guard rejects the model's output (or generation fails), `cleanedText`
/// equals the raw text, `fellBack` is `true` and `fallbackReason` says why.
public struct CleanedSegment: Sendable, Codable, Equatable {
    public let segment: Segment
    public let cleanedText: String
    public let fellBack: Bool
    public let fallbackReason: String?
    /// Time spent in the cleanup stage for this segment.
    public let latencyMs: Int

    public init(segment: Segment, cleanedText: String, fellBack: Bool, fallbackReason: String?, latencyMs: Int) {
        self.segment = segment
        self.cleanedText = cleanedText
        self.fellBack = fellBack
        self.fallbackReason = fallbackReason
        self.latencyMs = latencyMs
    }

    /// A result that keeps the raw text because cleanup could not be trusted or did not run.
    public static func fallback(_ segment: Segment, reason: String, latencyMs: Int) -> CleanedSegment {
        CleanedSegment(
            segment: segment,
            cleanedText: segment.rawText,
            fellBack: true,
            fallbackReason: reason,
            latencyMs: latencyMs
        )
    }
}

/// Per-stage latency of one segment, all in milliseconds.
public struct StageLatencies: Sendable, Codable, Equatable {
    /// Silence the segmenter waited for before closing the segment (audio time).
    public var vadMs: Int
    /// Speech-to-text time for the final transcription.
    public var sttMs: Int
    /// Cleanup time; `nil` when cleanup did not run.
    public var llmMs: Int?
    /// End of speech to final text on screen, including queueing; `nil` until final.
    public var totalMs: Int?

    public init(vadMs: Int, sttMs: Int, llmMs: Int? = nil, totalMs: Int? = nil) {
        self.vadMs = vadMs
        self.sttMs = sttMs
        self.llmMs = llmMs
        self.totalMs = totalMs
    }
}
