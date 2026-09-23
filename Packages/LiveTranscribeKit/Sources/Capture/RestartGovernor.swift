import Foundation

/// Limits how often capture restarts after a runtime error or a lost default microphone.
///
/// A device that fails again as soon as it reopens would otherwise restart forever. Past the
/// limit, capture stops with an error instead.
struct RestartGovernor {
    let maxRestarts: Int
    let window: Duration
    private var restarts: [ContinuousClock.Instant] = []

    init(maxRestarts: Int, window: Duration = .seconds(60)) {
        self.maxRestarts = max(1, maxRestarts)
        self.window = window
    }

    /// Records a restart at `now`. Returns `false`, and records nothing, when `maxRestarts`
    /// restarts already happened within the window.
    mutating func allowRestart(at now: ContinuousClock.Instant) -> Bool {
        restarts.removeAll { $0.duration(to: now) >= window }
        guard restarts.count < maxRestarts else { return false }
        restarts.append(now)
        return true
    }
}
