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
    public static let dictation = Logger(subsystem: subsystem, category: "Dictation")
    public static let hotkey = Logger(subsystem: subsystem, category: "Hotkey")
    public static let insertion = Logger(subsystem: subsystem, category: "Insertion")
    public static let permissions = Logger(subsystem: subsystem, category: "Permissions")
    public static let snippets = Logger(subsystem: subsystem, category: "Snippets")
    public static let vocabulary = Logger(subsystem: subsystem, category: "Vocabulary")

    /// Signposts for Instruments: STT and LLM calls are wrapped in intervals.
    public static let transcriptionSignposter = OSSignposter(logger: transcription)
    public static let cleanupSignposter = OSSignposter(logger: cleanup)
    /// Dictation intervals: hotkey down to first audio, and hotkey up to inserted text.
    public static let dictationSignposter = OSSignposter(logger: dictation)
}
