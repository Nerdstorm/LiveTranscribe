import Shared

/// Corrects transcription errors, punctuation, casing and grammar in one segment.
///
/// `clean` never throws and never drops text: on any failure it returns the text the model would
/// have corrected (the raw text, less fillers at Medium and High) with `fellBack == true` and a
/// reason.
public protocol Cleaner: Actor {
    func load(progress: @escaping ModelLoadProgressHandler) async throws
    /// - Parameters:
    ///   - context: previously cleaned segments, oldest first, used as read-only context.
    ///   - options: the level, vocabulary and placeholders for this segment.
    func clean(_ segment: Segment, context: [String], options: CleanupOptions) async -> CleanedSegment
}
