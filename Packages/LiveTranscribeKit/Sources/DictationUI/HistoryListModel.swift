import AppKit
import Foundation
import Observation
import Persistence
import Shared

/// State for the history window: the records, the search, the selection and what can be done
/// to them. Records come from ``DictationHistory/all()``, newest first, less any past the
/// retention set in Settings.
@MainActor
@Observable
final class HistoryListModel {
    /// What the list shows instead of rows.
    enum EmptyState: Equatable {
        /// History is off and nothing is kept.
        case historyOff
        /// History is on but nothing has been dictated yet.
        case noDictations
        /// Nothing matches the search.
        case noMatches(String)
    }

    /// Every record within the retention, newest first, as last loaded.
    private(set) var records: [DictationRecord] = [] {
        didSet { updateFilteredRecords() }
    }
    var searchText = "" {
        didSet { if searchText != oldValue { updateFilteredRecords() } }
    }
    /// The records matching ``searchText``, newest first: what the list shows. Kept up to date
    /// rather than computed, because the window reads it several times per update and a long
    /// history makes each search pass costly.
    private(set) var filteredRecords: [DictationRecord] = []
    var selection: DictationRecord.ID?
    private(set) var isLoading = false
    /// Whether a load has finished, so the empty state is not shown before the first one.
    private(set) var hasLoaded = false
    /// A readable message for the last failure; cleared by the next successful action.
    private(set) var errorMessage: String?

    @ObservationIgnored private let history: any DictationHistory
    @ObservationIgnored private let copyToPasteboard: @MainActor (String) -> Bool
    @ObservationIgnored private let retentionCutoff: @MainActor () -> Date?
    /// Bumped by every load, so an older load that finishes late cannot overwrite a newer one.
    @ObservationIgnored private var loadGeneration = 0

    /// - Parameters:
    ///   - copyToPasteboard: Puts text on the clipboard and reports whether it worked; tests
    ///     pass a fake.
    ///   - retentionCutoff: The oldest creation date to show, read at every load, or `nil` to
    ///     show everything (see ``HistoryRetention/cutoff(now:retentionDays:calendar:)``).
    init(
        history: any DictationHistory,
        copyToPasteboard: @escaping @MainActor (String) -> Bool = HistoryListModel.writeToGeneralPasteboard,
        retentionCutoff: @escaping @MainActor () -> Date? = { nil }
    ) {
        self.history = history
        self.copyToPasteboard = copyToPasteboard
        self.retentionCutoff = retentionCutoff
    }

    // MARK: - Derived state

    /// The selected record while the search shows it. A selection the search hides is kept, so
    /// clearing the search brings it back, but nothing acts on a row the user cannot see.
    var selectedRecord: DictationRecord? {
        guard let selection else { return nil }
        return filteredRecords.first { $0.id == selection }
    }

    /// What to show when there are no rows; `nil` when there are rows, or before the first load.
    func emptyState(historyEnabled: Bool) -> EmptyState? {
        guard hasLoaded, filteredRecords.isEmpty else { return nil }
        if records.isEmpty {
            return historyEnabled ? .noDictations : .historyOff
        }
        return .noMatches(searchText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Records whose cleaned text, raw text or app name contains `query`, ignoring case and
    /// accents ("cafe" finds "Café"). A blank query matches everything.
    static func filter(_ records: [DictationRecord], query: String) -> [DictationRecord] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return records }
        return records.filter { record in
            [record.cleanedText, record.rawText, record.appName ?? ""].contains { field in
                field.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
    }

    /// `records` without those past the retention `cutoff`, by the rule
    /// ``DictationHistory/prune(olderThan:)`` deletes them with. The dictation controller prunes
    /// only every so often, so the window hides what is due meanwhile.
    static func withinRetention(_ records: [DictationRecord], cutoff: Date?) -> [DictationRecord] {
        guard let cutoff else { return records }
        return records.filter { !$0.isPruned(olderThan: cutoff) }
    }

    private func updateFilteredRecords() {
        filteredRecords = Self.filter(records, query: searchText)
    }

    // MARK: - Intents

    /// Loads every record within the retention again. The selection is kept while its record
    /// is still shown.
    func reload() async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        defer { if generation == loadGeneration { isLoading = false } }
        do {
            let loaded = Self.withinRetention(try await history.all(), cutoff: retentionCutoff())
            guard generation == loadGeneration else { return }
            records = loaded
            errorMessage = nil
            if let selection, !loaded.contains(where: { $0.id == selection }) {
                self.selection = nil
            }
        } catch {
            guard generation == loadGeneration else { return }
            Log.ui.error("Could not load the dictation history: \(error.localizedDescription, privacy: .public)")
            errorMessage = "Couldn't load the history. \(error.localizedDescription)"
        }
        hasLoaded = true
    }

    /// Deletes one record and selects its neighbour in the visible list, so the Delete key can
    /// be pressed repeatedly.
    func delete(id: DictationRecord.ID) async {
        let visible = filteredRecords
        do {
            try await history.delete(id: id)
        } catch {
            Log.ui.error("Could not delete a dictation from history: \(error.localizedDescription, privacy: .public)")
            errorMessage = "Couldn't delete the dictation. \(error.localizedDescription)"
            return
        }
        errorMessage = nil
        records.removeAll { $0.id == id }
        guard selection == id else { return }
        if let index = visible.firstIndex(where: { $0.id == id }) {
            let remaining = visible.filter { $0.id != id }
            selection = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)].id
        } else {
            selection = nil
        }
    }

    /// Deletes every record. Returns whether it worked.
    @discardableResult
    func clearAll() async -> Bool {
        do {
            try await history.clear()
        } catch {
            Log.ui.error("Could not clear the dictation history: \(error.localizedDescription, privacy: .public)")
            errorMessage = "Couldn't clear the history. \(error.localizedDescription)"
            return false
        }
        Log.ui.info("Dictation history cleared from the history window")
        errorMessage = nil
        records = []
        selection = nil
        return true
    }

    /// Copies the delivered text of a record. Returns whether it worked.
    @discardableResult
    func copyCleaned(_ record: DictationRecord) -> Bool {
        copy(record.cleanedText)
    }

    /// Copies what speech-to-text heard, before any cleanup. Returns whether it worked.
    @discardableResult
    func copyOriginal(_ record: DictationRecord) -> Bool {
        copy(record.rawText)
    }

    private func copy(_ text: String) -> Bool {
        guard copyToPasteboard(text) else {
            Log.ui.error("Could not copy a dictation to the clipboard")
            errorMessage = "Couldn't copy the text to the clipboard."
            return false
        }
        errorMessage = nil
        return true
    }

    func dismissError() {
        errorMessage = nil
    }

    static func writeToGeneralPasteboard(_ text: String) -> Bool {
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
    }
}
