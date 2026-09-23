import Shared

/// Thresholds and durations for ``SegmentationStateMachine``.
public struct SegmentationConfig: Sendable, Equatable {
    /// Probability at or above which a chunk starts a segment.
    public var speechThreshold: Float
    /// Silence that ends a segment.
    public var silenceMs: Int
    /// Segments are force-closed at this length.
    public var maxSegmentMs: Int
    /// Audio kept from before speech started.
    public var preRollMs: Int
    /// Segments with less detected speech than this are discarded.
    public var minSpeechMs: Int
    /// Interval between partial snapshots of an open segment; 0 disables them.
    public var partialIntervalMs: Int

    public init(
        speechThreshold: Float,
        silenceMs: Int,
        maxSegmentMs: Int,
        preRollMs: Int,
        minSpeechMs: Int,
        partialIntervalMs: Int
    ) {
        self.speechThreshold = speechThreshold
        self.silenceMs = silenceMs
        self.maxSegmentMs = maxSegmentMs
        self.preRollMs = preRollMs
        self.minSpeechMs = minSpeechMs
        self.partialIntervalMs = partialIntervalMs
    }

    public init(settings: AppSettings) {
        self.init(
            speechThreshold: Float(settings.vadSpeechThreshold),
            silenceMs: settings.vadSilenceMs,
            maxSegmentMs: settings.maxSegmentSeconds * 1_000,
            preRollMs: settings.vadPreRollMs,
            minSpeechMs: settings.vadMinSpeechMs,
            partialIntervalMs: settings.partialIntervalMs
        )
    }

    /// Once a segment is open, only chunks below this probability count as silence.
    ///
    /// The 0.15 hysteresis follows Silero's reference implementation: it stops brief dips in
    /// probability mid-word from ending a segment.
    public var silenceThreshold: Float {
        max(speechThreshold - 0.15, 0.01)
    }
}
