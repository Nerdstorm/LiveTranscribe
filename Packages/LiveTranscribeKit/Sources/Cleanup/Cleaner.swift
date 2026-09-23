import Shared

/// Corrects transcription errors, punctuation, casing and grammar in one segment.
///
/// `clean` never throws and never drops text: on any failure it returns the raw text with
/// `fellBack == true` and a reason.
public protocol Cleaner: Actor {
    func load(progress: @escaping ModelLoadProgressHandler) async throws
    /// - Parameter context: previously cleaned segments, oldest first, used as read-only context.
    func clean(_ segment: Segment, context: [String]) async -> CleanedSegment
}
