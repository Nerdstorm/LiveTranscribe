import Foundation
import Insertion
import Observation
import Shared

/// Settings › Apps: the built-in per-app insertion settings (read-only) and the user's own
/// (editable), saved through ``InserterOverridesStore``.
///
/// The store keeps only the user's entries; the built-in ones live in code. For an app in both,
/// the user's entry wins (``InserterOverrides/merged(with:)``), and the built-in row says so.
///
/// Every change goes through ``InserterOverridesStore/update(_:)``, which re-reads the file and
/// changes only the one app in a single step on the store: writing the copy loaded when the tab
/// opened would drop an entry added by hand since, and a separate read and write could lose one
/// saved in between.
@MainActor
@Observable
final class AppOverridesModel {
    /// Shown when a chosen bundle has no bundle identifier to store a setting under.
    static let unidentifiedAppMessage = "That app has no bundle identifier, so it can\u{2019}t have its own setting."

    /// The user's settings, sorted by app name.
    private(set) var userRows: [AppOverrideRow] = []
    /// The built-in settings, sorted by app name.
    private(set) var builtInRows: [AppOverrideRow] = []
    /// Regular apps running now that don't have a setting of the user's, for the Add sheet.
    /// Refreshed by ``refreshRunningApps()``.
    private(set) var runningApps: [AppOverrideApp] = []
    let status: EditableListStatus

    private let store: InserterOverridesStore
    private let catalog: any AppOverrideAppCatalog
    private let builtIn: InserterOverrides
    private var user: InserterOverrides = .empty
    /// Apps already looked up, so Launch Services is asked once per bundle identifier.
    @ObservationIgnored private var appsByIdentifier: [String: AppOverrideApp] = [:]

    /// - Parameters:
    ///   - store: Where the user's settings live.
    ///   - catalog: Finds app names, icons and running apps.
    ///   - builtIn: The settings shipped with the app; tests pass a short list.
    init(store: InserterOverridesStore, catalog: any AppOverrideAppCatalog, builtIn: InserterOverrides = .bundled) {
        self.store = store
        self.catalog = catalog
        self.builtIn = builtIn
        status = EditableListStatus(fileURL: store.fileURL, subject: "per-app insertion settings")
    }

    /// Reads the user's settings. A damaged file is set aside by the store and noted in
    /// ``status``; an unreadable one leaves the load state failed, with its message.
    func load() async {
        if let loaded = await status.load({ try await store.load() }) {
            apply(loaded)
        }
    }

    /// The row with `id`, from either section.
    func row(id: AppOverrideRow.ID?) -> AppOverrideRow? {
        guard let id else { return nil }
        return userRows.first { $0.id == id } ?? builtInRows.first { $0.id == id }
    }

    /// Lists the regular apps running now, leaving out those the user already has a setting for.
    func refreshRunningApps() {
        var seen: Set<String> = []
        runningApps = catalog.runningApps()
            .filter { user.method(for: $0.bundleIdentifier) == nil && seen.insert($0.bundleIdentifier.lowercased()).inserted }
            .sorted(by: Self.byName)
        for app in runningApps { appsByIdentifier[app.bundleIdentifier] = app }
    }

    /// The app bundle the user chose in an Open panel, or `nil` when it has no bundle identifier
    /// (the sheet then shows ``unidentifiedAppMessage``).
    func chosenApp(at url: URL) -> AppOverrideApp? {
        guard let app = catalog.app(at: url) else {
            Log.ui.notice("The chosen app has no bundle identifier: \(url.path, privacy: .private)")
            return nil
        }
        appsByIdentifier[app.bundleIdentifier] = app
        return app
    }

    /// The method a new setting for this app starts with: the one it doesn't use now. An app
    /// with no setting tries Accessibility first, so a setting for it is most likely Paste; a
    /// built-in Paste app gets a setting to undo that.
    func suggestedMethod(for bundleIdentifier: String) -> InsertionMethod {
        let current = builtIn.merged(with: user).method(for: bundleIdentifier) ?? .accessibility
        return current == .paste ? .accessibility : .paste
    }

    /// A draft for a new setting; the app is chosen in the sheet.
    func newDraft() -> AppOverrideDraft {
        AppOverrideDraft(app: nil, method: .paste, isNew: true)
    }

    /// A draft that edits `row`. A built-in row can't be changed itself: its draft adds a setting
    /// of the user's for the same app, or edits the one they already have.
    func draft(for row: AppOverrideRow) -> AppOverrideDraft {
        if row.source == .builtIn, let own = userRows.first(where: { $0.bundleIdentifier.caseInsensitiveCompare(row.bundleIdentifier) == .orderedSame }) {
            return draft(for: own)
        }
        switch row.source {
        case .user: return AppOverrideDraft(app: row.app, method: row.method, isNew: false)
        case .builtIn: return AppOverrideDraft(app: row.app, method: suggestedMethod(for: row.bundleIdentifier), isNew: true)
        }
    }

    /// Whether `draft` can be saved: an app has been chosen, and a new setting isn't for an app
    /// that already has one.
    func validation(of draft: AppOverrideDraft) -> EditableListValidation {
        guard let app = draft.app else { return .incomplete("Choose an app.") }
        if draft.isNew, user.method(for: app.bundleIdentifier) != nil {
            return .invalid("You already have a setting for \(app.name). Edit it instead.")
        }
        return .valid
    }

    /// Adds or changes the setting for the draft's app. Any other entry for the same app in a
    /// different casing is replaced, so one app never has two settings.
    ///
    /// - Returns: Whether it was saved; when it wasn't, ``status`` holds the reason, or the draft
    ///   was not valid and nothing was attempted.
    @discardableResult
    func save(_ draft: AppOverrideDraft) async -> Bool {
        guard validation(of: draft).canSave, let app = draft.app else { return false }
        let bundleIdentifier = app.bundleIdentifier
        let method = draft.method
        return await status.perform(draft.isNew ? "add a per-app setting" : "save a per-app setting") {
            let overrides = try await store.update { overrides in
                overrides.methods = overrides.methods.filter {
                    $0.key.caseInsensitiveCompare(bundleIdentifier) != .orderedSame
                }
                overrides.methods[bundleIdentifier] = method
            }
            apply(overrides)
        }
    }

    /// Removes the user's setting stored under exactly `bundleIdentifier`; the built-in one, if
    /// any, applies again.
    ///
    /// - Returns: Whether it was removed; when it wasn't, ``status`` holds the reason.
    @discardableResult
    func delete(bundleIdentifier: String) async -> Bool {
        await status.perform("remove a per-app setting") {
            let overrides = try await store.update { $0.methods[bundleIdentifier] = nil }
            apply(overrides)
        }
    }

    // MARK: - Private

    private func apply(_ overrides: InserterOverrides) {
        user = overrides
        userRows = overrides.methods
            .map { AppOverrideRow(bundleIdentifier: $0.key, app: app(for: $0.key), method: $0.value, source: .user, isReplacedByUser: false) }
            .sorted { Self.byName($0.app, $1.app) }
        builtInRows = builtIn.methods
            .map { key, method in
                AppOverrideRow(
                    bundleIdentifier: key,
                    app: app(for: key),
                    method: method,
                    source: .builtIn,
                    isReplacedByUser: overrides.method(for: key) != nil
                )
            }
            .sorted { Self.byName($0.app, $1.app) }
    }

    /// How to show the app stored under `key`: its real name and icon when it is installed,
    /// otherwise the identifier itself. The result always carries `key` as its identifier.
    private func app(for key: String) -> AppOverrideApp {
        let found = appsByIdentifier[key] ?? catalog.app(bundleIdentifier: key)
        guard let found else { return .unresolved(key) }
        appsByIdentifier[key] = found
        return AppOverrideApp(bundleIdentifier: key, name: found.name, url: found.url)
    }

    /// Alphabetical by name, then by identifier so two apps with one name keep a fixed order.
    private static func byName(_ lhs: AppOverrideApp, _ rhs: AppOverrideApp) -> Bool {
        switch lhs.name.localizedStandardCompare(rhs.name) {
        case .orderedAscending: true
        case .orderedDescending: false
        case .orderedSame: lhs.bundleIdentifier < rhs.bundleIdentifier
        }
    }
}
