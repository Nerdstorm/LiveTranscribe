import Capture

/// Decides which microphone notices reach the HUD.
///
/// Dictation opens the microphone on every key press, and capture reports some situations each
/// time it opens: a virtual default input it skipped, or a chosen microphone that is missing. A
/// notice is shown once, then again only after the set of microphones changes or a different
/// notice is shown.
public struct CaptureNoticeFilter: Sendable {
    private var lastShown: CaptureNotice?

    public init() {}

    /// Whether `notice` should be shown; records it as shown when it should.
    public mutating func shouldShow(_ notice: CaptureNotice) -> Bool {
        guard notice != lastShown else { return false }
        lastShown = notice
        return true
    }

    /// Microphones were connected or disconnected: the next notice is news again.
    public mutating func devicesChanged() {
        lastShown = nil
    }
}
