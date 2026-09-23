import AppKit
import Hotkey
import Persistence
import Shared
import SwiftUI

/// The dictation history window: every kept dictation, newest first, with search, a detail
/// pane, and copy and delete. History stays on this Mac (decision H2), which the footer says.
///
/// Reloads when it appears, when one of the app's windows becomes key (which includes the app
/// becoming active), and on *Refresh*; state and actions live in ``HistoryListModel``.
public struct HistoryWindowView: View {
    let context: DictationUIContext

    @AppStorage(AppSettingsKey.historyEnabled.rawValue)
    private var historyEnabled = AppSettings.defaults.dictation.historyEnabled
    @AppStorage(AppSettingsKey.dictationHotkey.rawValue)
    private var dictationHotkey = AppSettings.defaults.dictation.hotkey

    @State private var model: HistoryListModel
    @State private var confirmingClearAll = false

    public init(context: DictationUIContext) {
        self.context = context
        _model = State(initialValue: HistoryListModel(history: context.history))
    }

    public var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if !historyEnabled, !model.records.isEmpty {
                banner("History is off. New dictations aren't saved.", systemImage: "pause.circle", isError: false) {
                    Button("History Settings…") { context.windows?.showSettings(tab: .history) }
                }
            }
            if let error = model.errorMessage {
                banner(error, systemImage: "exclamationmark.triangle.fill", isError: true) {
                    Button("Try Again") { Task { await model.reload() } }
                    Button { model.dismissError() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Dismiss")
                }
            }
            HSplitView {
                list
                    .frame(minWidth: 260, idealWidth: 320)
                detail
                    .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            Text("Stored only on this Mac. Never synced.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .frame(minWidth: 640, minHeight: 400)
        .task { await model.reload() }
        // A window becoming key covers the app becoming active (back from dictating elsewhere)
        // and a switch back from Settings, where the history may have been cleared.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            Task { await model.reload() }
        }
        .confirmationDialog("Clear all dictation history?", isPresented: $confirmingClearAll) {
            Button("Clear All", role: .destructive) { clearAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every saved dictation is deleted from this Mac. This can't be undone.")
        }
    }

    // MARK: - Parts

    private var toolbar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Search", text: $model.searchText, prompt: Text("Search text or app"))
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Search history")
                if !model.searchText.isEmpty {
                    Button { model.searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))

            Button { Task { await model.reload() } } label: { Image(systemName: "arrow.clockwise") }
                .help("Refresh")
                .accessibilityLabel("Refresh")
                .keyboardShortcut("r")
                .disabled(model.isLoading)
            Button("Clear All…", role: .destructive) { confirmingClearAll = true }
                .disabled(model.records.isEmpty)
        }
        .padding(10)
    }

    private var list: some View {
        List(model.filteredRecords, selection: $model.selection) { record in
            HistoryListRow(record: record)
                .tag(record.id)
        }
        .contextMenu(forSelectionType: DictationRecord.ID.self) { ids in
            if let id = ids.first, let record = model.filteredRecords.first(where: { $0.id == id }) {
                Button("Copy") { copy(record, original: false) }
                Button("Copy Original") { copy(record, original: true) }
                Divider()
                Button("Delete", role: .destructive) { delete(id) }
            }
        }
        .onDeleteCommand {
            if let record = model.selectedRecord { delete(record.id) }
        }
        .overlay { emptyState }
        .accessibilityLabel("Dictations")
    }

    @ViewBuilder private var emptyState: some View {
        switch model.emptyState(historyEnabled: historyEnabled) {
        case .historyOff:
            ContentUnavailableView {
                Label("History is off", systemImage: "clock.badge.xmark")
            } description: {
                Text("Turn on Keep dictation history to see your dictations here.")
            } actions: {
                Button("Open History Settings") { context.windows?.showSettings(tab: .history) }
            }
        case .noDictations:
            ContentUnavailableView(
                "No dictations yet",
                systemImage: "waveform",
                description: Text("Hold \(hotkeyName) in any app and speak. Your dictations appear here.")
            )
        case .noMatches(let query):
            ContentUnavailableView.search(text: query)
        case nil:
            if !model.hasLoaded { ProgressView() }
        }
    }

    @ViewBuilder private var detail: some View {
        if let record = model.selectedRecord {
            HistoryListDetail(
                record: record,
                onCopy: { copy(record, original: false) },
                onCopyOriginal: { copy(record, original: true) },
                onDelete: { delete(record.id) }
            )
        } else {
            Text("Select a dictation to see what was heard and how it was cleaned up.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func banner(
        _ message: String,
        systemImage: String,
        isError: Bool,
        @ViewBuilder actions: () -> some View
    ) -> some View {
        HStack(spacing: 8) {
            Label(message, systemImage: systemImage)
                .foregroundStyle(isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            actions()
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.3))
    }

    private var hotkeyName: String {
        HotkeyRecorderModel.binding(storage: dictationHotkey, fallback: .defaultDictation).displayName
    }

    // MARK: - Actions

    private func copy(_ record: DictationRecord, original: Bool) {
        let copied = original ? model.copyOriginal(record) : model.copyCleaned(record)
        if copied { SettingsRootAnnouncer.announce("Copied") }
    }

    private func delete(_ id: DictationRecord.ID) {
        Task {
            await model.delete(id: id)
            SettingsRootAnnouncer.announce(model.errorMessage ?? "Dictation deleted")
        }
    }

    private func clearAll() {
        Task {
            let cleared = await model.clearAll()
            SettingsRootAnnouncer.announce(cleared ? "History cleared" : (model.errorMessage ?? "Couldn't clear the history"))
        }
    }
}
