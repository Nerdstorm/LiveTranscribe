import Foundation

/// Limits how often capture restarts after a runtime error or a lost default microphone, and how
/// often it switches microphone after the default input changes.
///
/// A device that fails again as soon as it reopens would otherwise restart forever, and a default
/// input that keeps flipping would switch forever. Past the limit, capture stops with an error
/// (restarts) or stays where it is until switching is allowed again (switches).
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

    /// The earliest instant at which ``allowRestart(at:)`` would say yes: `now` when it would
    /// already, otherwise when the oldest restart in the window ages out. Lets a refused switch be
    /// retried once, instead of being dropped for good.
    func nextAllowedRestart(after now: ContinuousClock.Instant) -> ContinuousClock.Instant {
        let recent = restarts.filter { $0.duration(to: now) < window }
        guard recent.count >= maxRestarts, let oldest = recent.min() else { return now }
        return oldest + window
    }
}
