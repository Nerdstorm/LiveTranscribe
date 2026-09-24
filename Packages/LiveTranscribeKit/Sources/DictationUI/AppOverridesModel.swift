import Foundation
import Insertion
import Observation
import Shared

/// Settings › Apps: the built-in per-app settings (read-only) and the user's own (editable),
/// saved through ``AppOverridesStore``. Each setting is an insertion method and a line setting.
///
/// The store keeps only the user's entries; the built-in ones live in code. For an app in both,
/// the user's entry wins (``AppOverrides/merged(with:)``), and the built-in row says so. A row
/// shows what applies: an entry from before line settings, with a method only, shows the app's
/// built-in or default line setting, and saving it stores both.
///
/// Built-in settings are listed only for apps on this Mac; the others are counted
/// (``uninstalledBuiltInCount``) and apply once their app is installed. The user's settings are
/// all listed, an uninstalled app's under its bundle identifier, so each can still be deleted.
///
/// Every change goes through ``AppOverridesStore/update(_:)``, which re-reads the file and
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
    /// The built-in settings for apps on this Mac, sorted by app name.
    private(set) var builtInRows: [AppOverrideRow] = []
    /// How many built-in settings are for apps that aren't on this Mac, which aren't listed.
    private(set) var uninstalledBuiltInCount = 0
    /// Regular apps running now that don't have a setting of the user's, for the Add sheet.
    /// Refreshed by ``refreshRunningApps()``.
    private(set) var runningApps: [AppOverrideApp] = []
    let status: EditableListStatus

    private let store: AppOverridesStore
    private let catalog: any AppOverrideAppCatalog
    private let builtIn: AppOverrides
    private var user: AppOverrides = .empty
    /// Apps already looked up, so Launch Services is asked once per bundle identifier.
    @ObservationIgnored private var appsByIdentifier: [String: AppOverrideApp] = [:]

    /// - Parameters:
    ///   - store: Where the user's settings live.
    ///   - catalog: Finds app names, icons and running apps.
    ///   - builtIn: The settings shipped with the app; tests pass a short list.
    init(store: AppOverridesStore, catalog: any AppOverrideAppCatalog, builtIn: AppOverrides = .bundled) {
        self.store = store
        self.catalog = catalog
        self.builtIn = builtIn
        status = EditableListStatus(fileURL: store.fileURL, subject: "per-app settings")
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
            .filter { !user.hasOverride(for: $0.bundleIdentifier) && seen.insert($0.bundleIdentifier.lowercased()).inserted }
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

    /// What applies to this app now, from the user's setting, the built-in one or the defaults
    /// (Accessibility, multi-line). A new setting starts from it.
    func currentSettings(for bundleIdentifier: String) -> (method: InsertionMethod, lineMode: LineMode) {
        let current = builtIn.merged(with: user)
        return (current.method(for: bundleIdentifier) ?? .accessibility, current.lineMode(for: bundleIdentifier) ?? .multiLine)
    }

    /// A draft for a new setting, starting from the defaults; the app is chosen in the sheet.
    func newDraft() -> AppOverrideDraft {
        AppOverrideDraft(app: nil, method: .accessibility, lineMode: .multiLine, isNew: true)
    }

    /// A draft that edits `row`. A built-in row can't be changed itself: its draft adds a setting
    /// of the user's for the same app, or edits the one they already have.
    func draft(for row: AppOverrideRow) -> AppOverrideDraft {
        if row.source == .builtIn, let own = userRows.first(where: { $0.bundleIdentifier.caseInsensitiveCompare(row.bundleIdentifier) == .orderedSame }) {
            return draft(for: own)
        }
        return AppOverrideDraft(app: row.app, method: row.method, lineMode: row.lineMode, isNew: row.source == .builtIn)
    }

    /// Whether `draft` can be saved: an app has been chosen, a new setting isn't for an app that
    /// already has one, and it changes something about the app.
    func validation(of draft: AppOverrideDraft) -> EditableListValidation {
        guard let app = draft.app else { return .incomplete("Choose an app.") }
        guard draft.isNew else { return .valid }
        if user.hasOverride(for: app.bundleIdentifier) {
            return .invalid("You already have a setting for \(app.name). Edit it instead.")
        }
        let current = currentSettings(for: app.bundleIdentifier)
        if draft.method == current.method, draft.lineMode == current.lineMode {
            return .incomplete("Choose a setting \(app.name) doesn\u{2019}t already use.")
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
        let lineMode = draft.lineMode
        return await status.perform(draft.isNew ? "add a per-app setting" : "save a per-app setting") {
            let overrides = try await store.update { overrides in
                let otherApps: (String) -> Bool = { $0.caseInsensitiveCompare(bundleIdentifier) != .orderedSame }
                overrides.methods = overrides.methods.filter { otherApps($0.key) }
                overrides.lines = overrides.lines.filter { otherApps($0.key) }
                overrides.methods[bundleIdentifier] = method
                overrides.lines[bundleIdentifier] = lineMode
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
            let overrides = try await store.update { overrides in
                overrides.methods[bundleIdentifier] = nil
                overrides.lines[bundleIdentifier] = nil
            }
            apply(overrides)
        }
    }

    // MARK: - Private

    private func apply(_ overrides: AppOverrides) {
        user = overrides
        userRows = Self.apps(in: overrides)
            .map { key in
                let current = currentSettings(for: key)
                return AppOverrideRow(
                    bundleIdentifier: key,
                    app: app(for: key),
                    method: current.method,
                    lineMode: current.lineMode,
                    source: .user,
                    isReplacedByUser: false
                )
            }
            .sorted { Self.byName($0.app, $1.app) }
        let builtInApps = Self.apps(in: builtIn).map { (key: $0, app: app(for: $0)) }
        builtInRows = builtInApps
            .filter(\.app.isInstalled)
            .map { key, app in
                AppOverrideRow(
                    bundleIdentifier: key,
                    app: app,
                    method: builtIn.method(for: key) ?? .accessibility,
                    lineMode: builtIn.lineMode(for: key) ?? .multiLine,
                    source: .builtIn,
                    isReplacedByUser: overrides.hasOverride(for: key)
                )
            }
            .sorted { Self.byName($0.app, $1.app) }
        uninstalledBuiltInCount = builtInApps.count - builtInRows.count
    }

    /// Every bundle identifier with a setting of either kind in `overrides`.
    private static func apps(in overrides: AppOverrides) -> Set<String> {
        Set(overrides.methods.keys).union(overrides.lines.keys)
    }

    /// How to show the app stored under `key`: its real name and icon when it is installed,
    /// otherwise the identifier itself. The result always carries `key` as its identifier. Only
    /// apps that were found are remembered, so one installed later is found on the next load.
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
