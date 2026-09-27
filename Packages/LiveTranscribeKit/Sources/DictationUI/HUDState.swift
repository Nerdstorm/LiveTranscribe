import CoreGraphics
import Dictation
import Foundation

/// What the HUD shows: what its circle holds, and the message in the bubble beside it, if any.
///
/// Ordinary dictation is wordless. Only a notice that needs attention
/// (``DictationNotice/needsAttention``) is put in words: between dictations the controller's
/// notice, during one its progress notice.
struct HUDState: Equatable, Sendable {
    /// What the circle holds.
    enum Indicator: Equatable, Sendable {
        /// The microphone level, while recording. Hands-free adds a ring, because the recording
        /// ends only when the user presses again.
        case level(handsFree: Bool)
        /// A spinner, while transcribing.
        case spinner
        /// A glyph for a notice between dictations.
        case notice(isProblem: Bool)
    }

    let indicator: Indicator
    /// The bubble's text; `nil` for no bubble.
    let message: String?

    init(indicator: Indicator, message: String?) {
        self.indicator = indicator
        self.message = message
    }

    /// What the HUD shows for the controller's state; `nil` when it is hidden.
    ///
    /// - Parameters:
    ///   - phase: the controller's phase.
    ///   - notice: the controller's notice, shown only between dictations.
    ///   - progress: the controller's progress notice, shown only during one.
    init?(phase: DictationController.Phase, notice: DictationNotice?, progress: DictationNotice?) {
        switch phase {
        case .recording(let handsFree):
            self.init(indicator: .level(handsFree: handsFree), message: Self.words(for: progress))
        case .processing:
            self.init(indicator: .spinner, message: Self.words(for: progress))
        case .idle:
            guard let notice, notice.needsAttention else { return nil }
            self.init(indicator: .notice(isProblem: notice.isProblem), message: notice.message)
        }
    }

    private static func words(for notice: DictationNotice?) -> String? {
        guard let notice, notice.needsAttention else { return nil }
        return notice.message
    }
}

/// How the circle draws the microphone level: a red disc that grows with it, on a log scale.
enum HUDLevel {
    /// The level at which the disc starts to grow, and the one at which it is full size: the
    /// first and last thresholds of the five-bar meter it replaced, so it moves with normal speech.
    static let quiet: Float = 0.005
    static let loud: Float = 0.12
    /// The disc's radius in silence.
    static let minimumRadius: CGFloat = 6
    /// How much the disc's radius grows from silence to ``loud``.
    static let growth: CGFloat = 10

    /// `level` between ``quiet`` (0) and ``loud`` (1) on a log scale, clamped to 0...1; 0 for
    /// silence, a negative level or NaN.
    static func fraction(_ level: Float) -> CGFloat {
        guard level > 0 else { return 0 }
        let fraction = (log10(Double(level)) - log10(Double(quiet))) / (log10(Double(loud)) - log10(Double(quiet)))
        return CGFloat(min(max(fraction, 0), 1))
    }

    /// The disc's radius for `level`.
    static func discRadius(_ level: Float) -> CGFloat {
        minimumRadius + growth * fraction(level)
    }
}
