import Observation
import Persistence
import Shared

/// One choice in the history retention picker.
struct HistorySettingsRetentionOption: Identifiable, Equatable {
    /// The stored ``DictationSettings/historyRetentionDays`` value; 0 keeps everything.
    let days: Int

    var id: Int { days }

    /// The picker's choices, in days. Zero is *Forever* (decision H2: keep everything).
    static let standardDays = [0, 7, 30, 90, 365]
    /// The retention range the controller accepts, as ``DictationSettings/sanitized()`` clamps it.
    static let validDays = 0...3_650

    /// The standard choices, plus the stored value when it is none of them (set by hand or by
    /// an older version), so the picker always shows what is in effect. A stored value that
    /// means the same as a standard one (-1 is *Forever*) takes that one's place.
    static func options(including stored: Int) -> [HistorySettingsRetentionOption] {
        var days = standardDays
        if !days.contains(stored) {
            days.removeAll { effectiveDays($0) == effectiveDays(stored) }
            days.append(stored)
        }
        return days.sorted { effectiveDays($0) < effectiveDays($1) }.map(HistorySettingsRetentionOption.init)
    }

    /// The retention the controller applies for a stored value.
    static func effectiveDays(_ stored: Int) -> Int {
        min(max(stored, validDays.lowerBound), validDays.upperBound)
    }

    var title: String {
        switch Self.effectiveDays(days) {
        case 0: "Forever"
        case 1: "1 day"
        case 365: "1 year"
        case let days: "\(days) days"
        }
    }
}

/// Settings › History's *Clear History…*: deletes every dictation and reports the outcome.
@MainActor
@Observable
final class HistorySettingsModel {
    private(set) var isClearing = false
    /// A readable message when clearing failed; `nil` otherwise.
    private(set) var errorMessage: String?
    /// Set after a successful clear, until the next attempt.
    private(set) var didClear = false

    @ObservationIgnored private let history: any DictationHistory

    init(history: any DictationHistory) {
        self.history = history
    }

    /// Deletes every record. Returns whether it worked.
    @discardableResult
    func clear() async -> Bool {
        guard !isClearing else { return false }
        isClearing = true
        errorMessage = nil
        didClear = false
        defer { isClearing = false }
        do {
            try await history.clear()
            Log.ui.info("Dictation history cleared from Settings")
            didClear = true
            return true
        } catch {
            Log.ui.error("Could not clear the dictation history: \(error.localizedDescription, privacy: .public)")
            errorMessage = "Couldn't clear the history. \(error.localizedDescription)"
            return false
        }
    }
}
