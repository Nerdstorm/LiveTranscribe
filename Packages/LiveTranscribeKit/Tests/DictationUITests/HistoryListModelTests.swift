@testable import DictationUI
import Foundation
import Persistence
import Testing

@Suite("HistoryListModel")
@MainActor
struct HistoryListModelTests {
    /// Copied text, recorded by the fake pasteboard.
    private final class Clipboard {
        var texts: [String] = []
        var works = true
    }

    private let first = HistoryListFixtures.record(text: "Meet at the café", raw: "um meet at the cafe", app: "Mail", at: 0)
    private let second = HistoryListFixtures.record(text: "Ship it on Tuesday", app: "Slack", at: 60)
    private let third = HistoryListFixtures.record(text: "Résumé attached", app: nil, at: 120)

    /// A model over a history holding `first`, `second`, `third` in append order.
    private func loadedModel(clipboard: Clipboard = Clipboard()) async -> (HistoryListModel, MemoryDictationHistory) {
        let history = MemoryDictationHistory(records: [first, second, third])
        let model = HistoryListModel(history: history) { text in
            guard clipboard.works else { return false }
            clipboard.texts.append(text)
            return true
        }
        await model.reload()
        return (model, history)
    }

    // MARK: - Loading

    @Test func loadsNewestFirst() async {
        let (model, _) = await loadedModel()
        #expect(model.records.map(\.id) == [third.id, second.id, first.id])
        #expect(model.hasLoaded)
        #expect(!model.isLoading)
        #expect(model.errorMessage == nil)
    }

    @Test func reloadKeepsTheSelectionWhileItsRecordExists() async throws {
        let (model, history) = await loadedModel()
        model.selection = second.id
        await model.reload()
        #expect(model.selectedRecord == second)

        try await history.delete(id: second.id)
        await model.reload()
        #expect(model.selection == nil)
    }

    @Test func aFailedLoadIsReportedAndRetryClearsIt() async {
        let history = MemoryDictationHistory(records: [first])
        await history.setFailure(.readFailed("permission denied"))
        let model = HistoryListModel(history: history) { _ in true }
        await model.reload()
        #expect(model.errorMessage?.contains("permission denied") == true)
        #expect(model.hasLoaded)

        await history.setFailure(nil)
        await model.reload()
        #expect(model.errorMessage == nil)
        #expect(model.records == [first])
    }

    @Test func aSlowEarlierLoadCannotOverwriteANewerOne() async throws {
        let history = GatedHistory(records: [first])
        let model = HistoryListModel(history: history) { _ in true }
        // The first load reads [first], then waits at the gate.
        let slow = Task { await model.reload() }
        await history.waitUntilHeld()

        try await history.append(second)
        await model.reload()
        #expect(model.records.map(\.id) == [second.id, first.id])

        await history.open()
        await slow.value
        #expect(model.records.map(\.id) == [second.id, first.id], "the older result is dropped")
        #expect(!model.isLoading)
    }

    // MARK: - Retention

    /// The controller prunes only every so often, so the window hides what is already past the
    /// retention, by the rule the prune uses: a record made exactly at the cutoff is kept.
    @Test func recordsPastTheRetentionAreHidden() async {
        let history = MemoryDictationHistory(records: [first, second, third])
        var cutoff: Date? = second.createdAt
        let model = HistoryListModel(history: history, copyToPasteboard: { _ in true }, retentionCutoff: { cutoff })
        model.selection = first.id
        await model.reload()
        #expect(model.records.map(\.id) == [third.id, second.id])
        #expect(model.selection == nil, "a hidden record is not left selected")
        #expect(await history.records.count == 3, "the window only hides; the controller deletes")

        cutoff = nil
        await model.reload()
        #expect(model.records.map(\.id) == [third.id, second.id, first.id], "the cutoff is read at every load")
    }

    @Test func withinRetentionKeepsEverythingWithoutACutoff() {
        #expect(HistoryListModel.withinRetention([third, second, first], cutoff: nil) == [third, second, first])
        #expect(HistoryListModel.withinRetention([third, second, first], cutoff: third.createdAt.addingTimeInterval(1)).isEmpty)
    }

    // MARK: - Search

    @Test func searchMatchesCleanedTextRawTextAndAppNameIgnoringCaseAndAccents() async {
        let (model, _) = await loadedModel()
        model.searchText = "CAFE"
        #expect(model.filteredRecords.map(\.id) == [first.id])
        model.searchText = "um meet"
        #expect(model.filteredRecords.map(\.id) == [first.id], "raw text")
        model.searchText = "slack"
        #expect(model.filteredRecords.map(\.id) == [second.id], "app name")
        model.searchText = "resume"
        #expect(model.filteredRecords.map(\.id) == [third.id], "accents")
        model.searchText = "   "
        #expect(model.filteredRecords.count == 3, "a blank search shows everything")
    }

    @Test func aSelectionTheSearchHidesIsNotActedOn() async {
        let (model, _) = await loadedModel()
        model.selection = second.id
        model.searchText = "café"
        #expect(model.selectedRecord == nil, "the detail and Delete follow what the list shows")
        #expect(model.selection == second.id)
        model.searchText = ""
        #expect(model.selectedRecord == second, "clearing the search brings it back")
    }

    @Test func theFilteredListFollowsReloadsAndDeletes() async throws {
        let (model, history) = await loadedModel()
        model.searchText = "t"
        #expect(model.filteredRecords.map(\.id) == [third.id, second.id, first.id])
        await model.delete(id: second.id)
        #expect(model.filteredRecords.map(\.id) == [third.id, first.id])

        let fourth = HistoryListFixtures.record(text: "Later note", at: 180)
        try await history.append(fourth)
        await model.reload()
        #expect(model.filteredRecords.first?.id == fourth.id)
    }

    @Test func emptyStatesSayWhy() async {
        let (model, _) = await loadedModel()
        #expect(model.emptyState(historyEnabled: true) == nil)
        model.searchText = " zebra "
        #expect(model.emptyState(historyEnabled: true) == .noMatches("zebra"))

        let empty = HistoryListModel(history: MemoryDictationHistory()) { _ in true }
        #expect(empty.emptyState(historyEnabled: true) == nil, "nothing before the first load")
        await empty.reload()
        #expect(empty.emptyState(historyEnabled: true) == .noDictations)
        #expect(empty.emptyState(historyEnabled: false) == .historyOff)
    }

    // MARK: - Delete and clear

    @Test func deleteRemovesTheRecordAndSelectsTheNextOne() async throws {
        let (model, history) = await loadedModel()
        model.selection = third.id
        await model.delete(id: third.id)
        #expect(model.records.map(\.id) == [second.id, first.id])
        #expect(model.selection == second.id)
        #expect(try await history.all().map(\.id) == [second.id, first.id])

        // The last row selects the one above it.
        model.selection = first.id
        await model.delete(id: first.id)
        #expect(model.selection == second.id)

        await model.delete(id: second.id)
        #expect(model.selection == nil)
        #expect(model.records.isEmpty)
    }

    @Test func deletingAMiddleRowSelectsTheRowThatTakesItsPlace() async {
        let (model, _) = await loadedModel()
        model.selection = second.id
        await model.delete(id: second.id)
        #expect(model.selection == first.id)
    }

    @Test func deletingWhileSearchingSelectsTheNextVisibleRow() async {
        let (model, _) = await loadedModel()
        model.searchText = "at" // "Résumé attached" and "Meet at the café"; "Ship it on Tuesday" is hidden
        #expect(model.filteredRecords.map(\.id) == [third.id, first.id])
        model.selection = third.id
        await model.delete(id: third.id)
        #expect(model.selection == first.id, "not the hidden record that follows it in the full list")
    }

    @Test func deletingAnotherRecordKeepsTheSelection() async {
        let (model, _) = await loadedModel()
        model.selection = first.id
        await model.delete(id: third.id)
        #expect(model.selection == first.id)
    }

    @Test func aFailedDeleteKeepsTheRecordAndSaysSo() async {
        let (model, history) = await loadedModel()
        await history.setFailure(.rewriteFailed("read-only volume"))
        await model.delete(id: first.id)
        #expect(model.records.count == 3)
        #expect(model.errorMessage?.contains("read-only volume") == true)
    }

    @Test func clearAllEmptiesTheHistory() async throws {
        let (model, history) = await loadedModel()
        model.selection = first.id
        #expect(await model.clearAll())
        #expect(model.records.isEmpty)
        #expect(model.selection == nil)
        #expect(try await history.all().isEmpty)
    }

    @Test func aFailedClearAllKeepsEverything() async {
        let (model, history) = await loadedModel()
        await history.setFailure(.rewriteFailed("disk full"))
        #expect(await model.clearAll() == false)
        #expect(model.records.count == 3)
        #expect(model.errorMessage != nil)
        model.dismissError()
        #expect(model.errorMessage == nil)
    }

    // MARK: - Copy

    @Test func copiesTheInsertedTextOrWhatWasSaid() async {
        let clipboard = Clipboard()
        let (model, _) = await loadedModel(clipboard: clipboard)
        #expect(model.copyCleaned(first))
        #expect(model.copyOriginal(first))
        #expect(clipboard.texts == ["Meet at the café", "um meet at the cafe"])

        clipboard.works = false
        #expect(!model.copyCleaned(first))
        #expect(model.errorMessage != nil)
    }
}
