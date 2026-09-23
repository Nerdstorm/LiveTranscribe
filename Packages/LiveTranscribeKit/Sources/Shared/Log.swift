import Foundation
import os

/// One `os.Logger` per slice, all under the app's subsystem.
///
/// Transcript text is user speech: interpolate it only with `privacy: .private`. The same goes for
/// file paths (they contain the account name) and device names (they often contain a person's name).
public enum Log {
    /// The bundle id when running inside the app; a stable fallback for tests and the bench.
    public static let subsystem = Bundle.main.bundleIdentifier ?? "org.nerdstorm.LiveTranscribe"

    public static let app = Logger(subsystem: subsystem, category: "App")
    public static let capture = Logger(subsystem: subsystem, category: "Capture")
    public static let segmentation = Logger(subsystem: subsystem, category: "Segmentation")
    public static let transcription = Logger(subsystem: subsystem, category: "Transcription")
    public static let cleanup = Logger(subsystem: subsystem, category: "Cleanup")
    public static let persistence = Logger(subsystem: subsystem, category: "Persistence")
    public static let session = Logger(subsystem: subsystem, category: "Session")
    public static let ui = Logger(subsystem: subsystem, category: "UI")

    /// Signposts for Instruments: STT and LLM calls are wrapped in intervals.
    public static let transcriptionSignposter = OSSignposter(logger: transcription)
    public static let cleanupSignposter = OSSignposter(logger: cleanup)
}
