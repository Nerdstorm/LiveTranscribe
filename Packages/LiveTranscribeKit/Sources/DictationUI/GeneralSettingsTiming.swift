import Foundation
import Shared
import SwiftUI

/// One dictation timing setting in the *Timing* group: its key, label, range and step.
///
/// Ranges repeat ``DictationSettings/sanitized()``'s clamps exactly, so a stepper can never
/// reach a value the controller would silently change; a test holds the two together. Steps are
/// only how far one click moves.
struct GeneralSettingsTimingField: Identifiable {
    enum Value {
        case int(WritableKeyPath<DictationSettings, Int>, range: ClosedRange<Int>, step: Int)
        case double(WritableKeyPath<DictationSettings, Double>, range: ClosedRange<Double>, step: Double, fractionDigits: Int)
    }

    let key: AppSettingsKey
    /// Short label; the value and unit follow it ("Longest tap: 300 ms").
    let label: String
    /// Unit after the value, or "" for a plain number.
    let unit: String
    /// What the setting does, for the tooltip.
    let help: String
    let value: Value

    var id: String { key.rawValue }

    /// What the controller applies for a stored value: clamped into `range`, as
    /// ``DictationSettings/sanitized()`` does. A stepper shows this, so a value set outside the
    /// range (by hand, or by an older version) is shown as it takes effect.
    static func effective<Number: Comparable>(_ stored: Number, in range: ClosedRange<Number>) -> Number {
        min(max(stored, range.lowerBound), range.upperBound)
    }

    /// A stepped fractional value rounded to the digits shown, so stepping 0.8 by 0.05 stores
    /// 0.85 rather than 0.8500000000000001.
    static func rounded(_ value: Double, fractionDigits: Int) -> Double {
        let scale = pow(10, Double(fractionDigits))
        return (value * scale).rounded() / scale
    }

    /// Every field, in display order.
    static var all: [GeneralSettingsTimingField] {
        [
            .init(key: .hotkeyTapMaxMs, label: "Longest tap", unit: "ms",
                  help: "A press shorter than this is a tap, not push-to-talk.",
                  value: .int(\.tapMaxMs, range: 100...1_000, step: 50)),
            .init(key: .hotkeyDoubleTapWindowMs, label: "Double-tap window", unit: "ms",
                  help: "How soon a second tap must follow the first to start hands-free dictation.",
                  value: .int(\.doubleTapWindowMs, range: 100...1_000, step: 50)),
            .init(key: .dictationMinUtteranceMs, label: "Shortest recording", unit: "ms",
                  help: "Shorter recordings are discarded as too short to be speech.",
                  value: .int(\.minUtteranceMs, range: 0...2_000, step: 50)),
            .init(key: .dictationMaxRecordingSeconds, label: "Longest recording", unit: "s",
                  help: "A recording stops growing at this length.",
                  value: .int(\.maxRecordingSeconds, range: 10...1_800, step: 10)),
            .init(key: .dictationPreRollMs, label: "Pre-roll", unit: "ms",
                  help: "Audio from before the key press that is kept when the microphone is kept ready.",
                  value: .int(\.preRollMs, range: 0...2_000, step: 50)),
            .init(key: .undoWindowSeconds, label: "Undo AI edit window", unit: "s",
                  help: "How long after an insertion Undo AI edit still applies.",
                  value: .int(\.undoWindowSeconds, range: 5...600, step: 5)),
            .init(key: .dictationNoticeSeconds, label: "Message duration", unit: "s",
                  help: "How long a message stays up near the cursor.",
                  value: .double(\.noticeSeconds, range: 0.5...10, step: 0.5, fractionDigits: 1)),
            .init(key: .pasteRestoreDelayMs, label: "Clipboard restore delay", unit: "ms",
                  help: "Wait after pasting before the clipboard is put back.",
                  value: .int(\.pasteRestoreDelayMs, range: 50...5_000, step: 50)),
            .init(key: .undoSettleDelayMs, label: "Wait after ⌘Z", unit: "ms",
                  help: "Wait after ⌘Z before Undo AI edit inserts what you said.",
                  value: .int(\.undoSettleDelayMs, range: 0...2_000, step: 50)),
            .init(key: .accessibilityTimeoutMs, label: "Accessibility timeout", unit: "ms",
                  help: "Longest wait for another app to answer an Accessibility request.",
                  value: .int(\.accessibilityTimeoutMs, range: 50...5_000, step: 50)),
            .init(key: .accessibilityVerificationDelayMs, label: "Accessibility recheck delay", unit: "ms",
                  help: "Wait before reading a field again when typing into it seems ignored.",
                  value: .int(\.accessibilityVerificationDelayMs, range: 0...1_000, step: 25)),
            .init(key: .vocabularyPromptLimit, label: "Vocabulary terms per dictation", unit: "",
                  help: "Most vocabulary terms given to the cleanup model for one dictation.",
                  value: .int(\.vocabularyPromptLimit, range: 0...200, step: 5)),
            .init(key: .vocabularySimilarityThreshold, label: "Vocabulary match threshold", unit: "",
                  help: "How closely a spoken word must match a vocabulary term for the term to be used.",
                  value: .double(\.vocabularySimilarityThreshold, range: 0.5...1, step: 0.05, fractionDigits: 2)),
        ]
    }
}

/// The collapsed *Timing* group at the bottom of Settings › General: one stepper per
/// ``GeneralSettingsTimingField``. Changes apply to the next dictation.
struct GeneralSettingsTimingSection: View {
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup("Timing", isExpanded: $isExpanded) {
            ForEach(GeneralSettingsTimingField.all) { field in
                switch field.value {
                case .int(let keyPath, let range, let step):
                    GeneralSettingsIntStepper(field: field, defaultValue: AppSettings.defaults.dictation[keyPath: keyPath], range: range, step: step)
                case .double(let keyPath, let range, let step, let digits):
                    GeneralSettingsDoubleStepper(
                        field: field, defaultValue: AppSettings.defaults.dictation[keyPath: keyPath],
                        range: range, step: step, fractionDigits: digits
                    )
                }
            }
        }
    }
}

/// A whole-number timing stepper bound to its UserDefaults key.
private struct GeneralSettingsIntStepper: View {
    let field: GeneralSettingsTimingField
    let range: ClosedRange<Int>
    let step: Int
    @AppStorage private var value: Int

    init(field: GeneralSettingsTimingField, defaultValue: Int, range: ClosedRange<Int>, step: Int) {
        self.field = field
        self.range = range
        self.step = step
        _value = AppStorage(wrappedValue: defaultValue, field.key.rawValue)
    }

    var body: some View {
        let shown = GeneralSettingsTimingField.effective(value, in: range)
        Stepper(value: Binding(get: { shown }, set: { value = $0 }), in: range, step: step) {
            Text("\(field.label): \(shown)\(field.unit.isEmpty ? "" : " \(field.unit)")")
        }
        .help(field.help)
    }
}

/// A fractional timing stepper bound to its UserDefaults key.
private struct GeneralSettingsDoubleStepper: View {
    let field: GeneralSettingsTimingField
    let range: ClosedRange<Double>
    let step: Double
    let fractionDigits: Int
    @AppStorage private var value: Double

    init(field: GeneralSettingsTimingField, defaultValue: Double, range: ClosedRange<Double>, step: Double, fractionDigits: Int) {
        self.field = field
        self.range = range
        self.step = step
        self.fractionDigits = fractionDigits
        _value = AppStorage(wrappedValue: defaultValue, field.key.rawValue)
    }

    var body: some View {
        let shown = GeneralSettingsTimingField.effective(value, in: range)
        let binding = Binding(
            get: { shown },
            set: { value = GeneralSettingsTimingField.rounded($0, fractionDigits: fractionDigits) }
        )
        Stepper(value: binding, in: range, step: step) {
            Text("\(field.label): \(shown, format: .number.precision(.fractionLength(fractionDigits)))\(field.unit.isEmpty ? "" : " \(field.unit)")")
        }
        .help(field.help)
    }
}
