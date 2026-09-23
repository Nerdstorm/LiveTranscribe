import Foundation
import Shared

/// How capture recovers when the capture session fails or its microphone goes away, and how
/// eagerly it follows device changes.
public struct CaptureRestartPolicy: Sendable, Equatable {
    /// Consecutive failed start attempts per recovery before giving up.
    public let maxAttempts: Int
    /// Wait before each restart attempt, and before acting on a device change, so the system can
    /// settle: pick a new default device, or finish listing a newly connected one. Changes that
    /// arrive during the wait are handled together.
    public let delaySeconds: Double
    /// Recoveries allowed in any 60 s window before capture stops with an error. Switches to
    /// another device after a default-input change are limited to the same number, counted
    /// separately; past it, capture stays on its current device until a switch is allowed again,
    /// then follows wherever the default settled.
    public let maxRestartsPerMinute: Int

    public init(maxAttempts: Int, delaySeconds: Double, maxRestartsPerMinute: Int) {
        self.maxAttempts = max(0, maxAttempts)
        self.delaySeconds = max(0, delaySeconds)
        self.maxRestartsPerMinute = max(1, maxRestartsPerMinute)
    }

    public init(settings: AppSettings) {
        self.init(
            maxAttempts: settings.captureRestartAttempts,
            delaySeconds: settings.captureRestartDelaySeconds,
            maxRestartsPerMinute: settings.captureMaxRestartsPerMinute
        )
    }
}
