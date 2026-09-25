import Foundation

/// Every tunable in the app. Slices receive the values they need through their initialisers.
///
/// Model and pipeline values are read once at launch, so changes to them apply on the next
/// launch. Values documented as "read at each use" are loaded again whenever they are needed,
/// so they apply immediately.
public struct AppSettings: Sendable, Equatable {
    /// Speech-to-text model repository.
    public var sttModel: String
    /// Cleanup LLM repository.
    public var llmModel: String
    /// Voice activity detection model repository.
    public var vadModel: String
    /// Kill switch for cleanup. When `false` the LLM is never loaded and output is raw-only.
    public var cleanupEnabled: Bool
    /// Loads the bundled fine-tuned adapter, which resolves spoken self-corrections ("cars,
    /// sorry, buses" → "buses"), into the cleanup LLM. Applies only to the model it was trained on.
    public var cleanupAdapterEnabled: Bool
    /// How much cleanup may change what was said, for dictation and the live transcript alike.
    /// Read at each use: every dictation and every Start.
    public var cleanupLevel: CleanupLevel
    /// Silence that ends a segment.
    public var vadSilenceMs: Int
    /// Silero speech probability that starts a segment.
    public var vadSpeechThreshold: Double
    /// Audio kept from before speech starts, so the first word is not clipped.
    public var vadPreRollMs: Int
    /// Segments with less detected speech than this are discarded as noise.
    public var vadMinSpeechMs: Int
    /// Segments are force-closed at this length.
    public var maxSegmentSeconds: Int
    /// How often the in-progress segment is re-transcribed for live partials. 0 disables partials.
    public var partialIntervalMs: Int
    /// Prior cleaned segments sent to the LLM as read-only context.
    public var contextSegments: Int
    /// Per-segment deadline for cleanup.
    public var cleanupTimeoutSeconds: Double
    /// Pending cleanup jobs kept before the oldest is dropped (its raw text is still saved).
    public var cleanupQueueCapacity: Int
    /// Cap on MLX's Metal buffer cache.
    public var gpuCacheLimitMB: Int
    /// Capture restart attempts after a capture failure before giving up.
    public var captureRestartAttempts: Int
    /// Wait before each capture restart attempt.
    public var captureRestartDelaySeconds: Double
    /// Capture restarts allowed in any 60 s window before capture stops with an error, instead of
    /// looping on a microphone that keeps failing.
    public var captureMaxRestartsPerMinute: Int
    /// System-wide dictation: read at each use.
    public var dictation: DictationSettings

    public init(
        sttModel: String,
        llmModel: String,
        vadModel: String,
        cleanupEnabled: Bool,
        cleanupAdapterEnabled: Bool,
        cleanupLevel: CleanupLevel,
        vadSilenceMs: Int,
        vadSpeechThreshold: Double,
        vadPreRollMs: Int,
        vadMinSpeechMs: Int,
        maxSegmentSeconds: Int,
        partialIntervalMs: Int,
        contextSegments: Int,
        cleanupTimeoutSeconds: Double,
        cleanupQueueCapacity: Int,
        gpuCacheLimitMB: Int,
        captureRestartAttempts: Int,
        captureRestartDelaySeconds: Double,
        captureMaxRestartsPerMinute: Int,
        dictation: DictationSettings
    ) {
        self.sttModel = sttModel
        self.llmModel = llmModel
        self.vadModel = vadModel
        self.cleanupEnabled = cleanupEnabled
        self.cleanupAdapterEnabled = cleanupAdapterEnabled
        self.cleanupLevel = cleanupLevel
        self.vadSilenceMs = vadSilenceMs
        self.vadSpeechThreshold = vadSpeechThreshold
        self.vadPreRollMs = vadPreRollMs
        self.vadMinSpeechMs = vadMinSpeechMs
        self.maxSegmentSeconds = maxSegmentSeconds
        self.partialIntervalMs = partialIntervalMs
        self.contextSegments = contextSegments
        self.cleanupTimeoutSeconds = cleanupTimeoutSeconds
        self.cleanupQueueCapacity = cleanupQueueCapacity
        self.gpuCacheLimitMB = gpuCacheLimitMB
        self.captureRestartAttempts = captureRestartAttempts
        self.captureRestartDelaySeconds = captureRestartDelaySeconds
        self.captureMaxRestartsPerMinute = captureMaxRestartsPerMinute
        self.dictation = dictation
    }

    public static let defaults = AppSettings(
        sttModel: "mlx-community/Qwen3-ASR-0.6B-8bit",
        llmModel: "mlx-community/Qwen3-1.7B-4bit",
        vadModel: "mlx-community/silero-vad",
        cleanupEnabled: true,
        cleanupAdapterEnabled: true,
        cleanupLevel: .medium,
        vadSilenceMs: 600,
        vadSpeechThreshold: 0.5,
        vadPreRollMs: 200,
        vadMinSpeechMs: 250,
        maxSegmentSeconds: 15,
        partialIntervalMs: 1_000,
        contextSegments: 3,
        cleanupTimeoutSeconds: 3,
        cleanupQueueCapacity: 8,
        gpuCacheLimitMB: 512,
        captureRestartAttempts: 5,
        captureRestartDelaySeconds: 1,
        captureMaxRestartsPerMinute: 6,
        dictation: .defaults
    )

    /// The same settings with every value clamped to a range the pipeline can run with.
    public func sanitized() -> AppSettings {
        let fallback = AppSettings.defaults
        var copy = self
        copy.sttModel = sttModel.trimmed(or: fallback.sttModel)
        copy.llmModel = llmModel.trimmed(or: fallback.llmModel)
        copy.vadModel = vadModel.trimmed(or: fallback.vadModel)
        copy.vadSilenceMs = vadSilenceMs.clamped(to: 100...5_000)
        copy.vadSpeechThreshold = vadSpeechThreshold.clamped(to: 0.05...0.95)
        copy.vadPreRollMs = vadPreRollMs.clamped(to: 0...2_000)
        copy.vadMinSpeechMs = vadMinSpeechMs.clamped(to: 0...5_000)
        copy.maxSegmentSeconds = maxSegmentSeconds.clamped(to: 2...60)
        copy.partialIntervalMs = partialIntervalMs <= 0 ? 0 : partialIntervalMs.clamped(to: 250...10_000)
        copy.contextSegments = contextSegments.clamped(to: 0...20)
        copy.cleanupTimeoutSeconds = cleanupTimeoutSeconds.clamped(to: 0.5...30)
        copy.cleanupQueueCapacity = cleanupQueueCapacity.clamped(to: 1...64)
        copy.gpuCacheLimitMB = gpuCacheLimitMB.clamped(to: 0...16_384)
        copy.captureRestartAttempts = captureRestartAttempts.clamped(to: 0...20)
        copy.captureRestartDelaySeconds = captureRestartDelaySeconds.clamped(to: 0...30)
        copy.captureMaxRestartsPerMinute = captureMaxRestartsPerMinute.clamped(to: 1...60)
        copy.dictation = dictation.sanitized()
        return copy
    }
}

private extension String {
    func trimmed(or fallback: String) -> String {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? fallback : value
    }
}
