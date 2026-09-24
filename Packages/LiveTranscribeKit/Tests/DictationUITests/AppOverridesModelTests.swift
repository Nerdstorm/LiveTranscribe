@testable import DictationUI
import Foundation
import Insertion
import Testing

/// A fixed set of installed and running apps, so the tests never ask Launch Services.
@MainActor
private final class FakeAppCatalog: AppOverrideAppCatalog {
    var installed: [String: AppOverrideApp] = [:]
    var bundles: [URL: AppOverrideApp] = [:]
    var running: [AppOverrideApp] = []

    init(installed: [AppOverrideApp], running: [AppOverrideApp] = []) {
        for app in installed { self.installed[app.bundleIdentifier] = app }
        self.running = running
    }

    func app(bundleIdentifier: String) -> AppOverrideApp? { installed[bundleIdentifier] }
    func app(at url: URL) -> AppOverrideApp? { bundles[url] }
    func runningApps() -> [AppOverrideApp] { running }
}

/// Settings › Apps against a real ``AppOverridesStore`` on a temporary file.
@Suite("AppOverridesModel")
@MainActor
struct AppOverridesModelTests {
    private static let fileName = AppOverridesStore.fileName
    private static let terminal = AppOverrideApp(bundleIdentifier: "com.apple.Terminal", name: "Terminal", url: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
    private static let chrome = AppOverrideApp(bundleIdentifier: "com.google.Chrome", name: "Google Chrome", url: URL(fileURLWithPath: "/Applications/Google Chrome.app"))
    private static let notes = AppOverrideApp(bundleIdentifier: "com.apple.Notes", name: "Notes", url: URL(fileURLWithPath: "/System/Applications/Notes.app"))
    private static let bbedit = AppOverrideApp(bundleIdentifier: "com.barebones.bbedit", name: "BBEdit", url: URL(fileURLWithPath: "/Applications/BBEdit.app"))
    /// Built in like the real list, but short. `io.alacritty` is not installed in the fake.
    private static let builtIn = AppOverrides(
        methods: ["com.apple.Terminal": .paste, "com.google.Chrome": .paste, "io.alacritty": .paste],
        lines: ["com.apple.Terminal": .singleLine, "io.alacritty": .singleLine]
    )

    private func makeModel(
        in folder: EditableListTemporaryFolder,
        catalog: FakeAppCatalog = FakeAppCatalog(installed: [terminal, chrome, notes, bbedit])
    ) -> (AppOverridesModel, AppOverridesStore) {
        let store = AppOverridesStore(fileURL: folder.file(Self.fileName), now: { EditableListTemporaryFolder.fixedDate })
        return (AppOverridesModel(store: store, catalog: catalog, builtIn: Self.builtIn), store)
    }

    @Test func builtInSettingsAreListedByNameOnlyForAppsOnThisMac() async {
        let folder = EditableListTemporaryFolder()
        defer { folder.cleanUp() }
        let (model, _) = makeModel(in: folder)

        await model.load()

        #expect(model.status.loadState == .loaded)
        #expect(model.userRows.isEmpty)
        // io.alacritty isn't installed, so it is counted rather than listed by its identifier.
        #expect(model.builtInRows.map(\.app.name) == ["Google Chrome", "Terminal"])
        #expect(model.builtInRows.allSatisfy { $0.method == .paste && $0.source == .builtIn && !$0.isReplacedByUser })
        #expect(model.builtInRows.map(\.lineMode) == [.multiLine, .singleLine])
        #expect(model.uninstalledBuiltInCount == 1)
    }

    @Test func theRealBuiltInListIsUsedByDefault() async {
        let folder = EditableListTemporaryFolder()
        defer { folder.cleanUp() }
        let bundled = Set(AppOverrides.bundled.methods.keys).union(AppOverrides.bundled.lines.keys)
        let everything = bundled.map { AppOverrideApp(bundleIdentifier: $0, name: $0, url: URL(fileURLWithPath: "/Applications/\($0).app")) }

        let onAMacWithAll = AppOverridesModel(store: AppOverridesStore(fileURL: folder.file(Self.fileName)), catalog: FakeAppCatalog(installed: everything))
        await onAMacWithAll.load()
        #expect(Set(onAMacWithAll.builtInRows.map(\.bundleIdentifier)) == bundled)
        #expect(onAMacWithAll.uninstalledBuiltInCount == 0)

        let onAMacWithNone = AppOverridesModel(store: AppOverridesStore(fileURL: folder.file(Self.fileName)), catalog: FakeAppCatalog(installed: []))
        await onAMacWithNone.load()
        #expect(onAMacWithNone.builtInRows.isEmpty)
        #expect(onAMacWithNone.uninstalledBuiltInCount == bundled.count)
    }

    @Test func aBuiltInAppInstalledLaterIsListedOnTheNextLoad() async {
        let folder = EditableListTemporaryFolder()
        defer { folder.cleanUp() }
        let catalog = FakeAppCatalog(installed: [Self.terminal, Self.chrome])
        let (model, _) = makeModel(in: folder, catalog: catalog)
        await model.load()
        #expect(model.uninstalledBuiltInCount == 1)

        let alacritty = AppOverrideApp(bundleIdentifier: "io.alacritty", name: "Alacritty", url: URL(fileURLWithPath: "/Applications/Alacritty.app"))
        catalog.installed[alacritty.bundleIdentifier] = alacritty
        await model.load()

        #expect(model.builtInRows.map(\.app.name) == ["Alacritty", "Google Chrome", "Terminal"])
        #expect(model.uninstalledBuiltInCount == 0)
    }

    @Test func aSettingOfYoursStaysListedAfterItsAppIsGone() async throws {
        // It still applies if the app comes back, and the user must be able to delete it.
        let folder = EditableListTemporaryFolder()
        defer { folder.cleanUp() }
        let (model, store) = makeModel(in: folder)
        try await store.save(AppOverrides(methods: ["io.alacritty": .accessibility], lines: ["io.alacritty": .multiLine]))
        await model.load()

        let row = try #require(model.userRows.first)
        #expect(row.bundleIdentifier == "io.alacritty")
        #expect(row.app.name == "io.alacritty")
        #expect(!row.app.isInstalled)
        #expect(!model.builtInRows.contains { $0.bundleIdentifier == "io.alacritty" })
        #expect(model.uninstalledBuiltInCount == 1)

        #expect(await model.delete(bundleIdentifier: row.bundleIdentifier))
        #expect(model.userRows.isEmpty)
        #expect(try await store.load() == .empty)
    }

    @Test func aUserSettingForABuiltInAppWinsAndTheBuiltInRowSaysSo() async throws {
        let folder = EditableListTemporaryFolder()
        defer { folder.cleanUp() }
        let (model, store) = makeModel(in: folder)
        await model.load()
        let terminalRow = try #require(model.builtInRows.first { $0.bundleIdentifier == Self.terminal.bundleIdentifier })

        var draft = model.draft(for: terminalRow)
        #expect(draft.isNew)
        #expect(draft.method == .paste && draft.lineMode == .singleLine, "starts from the built-in setting")
        #expect(model.validation(of: draft) == .incomplete("Choose a setting Terminal doesn\u{2019}t already use."))
        draft.method = .accessibility
        #expect(await model.save(draft))

        #expect(try await store.load() == AppOverrides(
            methods: ["com.apple.Terminal": .accessibility], lines: ["com.apple.Terminal": .singleLine]
        ))
        #expect(model.userRows.map(\.app) == [Self.terminal])
        #expect(model.builtInRows.first { $0.bundleIdentifier == Self.terminal.bundleIdentifier }?.isReplacedByUser == true)
        // Changing the built-in row again edits the user's setting instead of adding another.
        let again = model.draft(for: try #require(model.row(id: terminalRow.id)))
        #expect(!again.isNew)
        #expect(again.method == .accessibility && again.lineMode == .singleLine)
    }

    @Test func aNewSettingStartsFromWhatAppliesNow() async throws {
        let folder = EditableListTemporaryFolder()
        defer { folder.cleanUp() }
        let (model, store) = makeModel(in: folder)
        try await store.save(AppOverrides(methods: ["com.google.Chrome": .accessibility]))
        await model.load()

        #expect(model.currentSettings(for: Self.notes.bundleIdentifier) == (.accessibility, .multiLine))
        #expect(model.currentSettings(for: Self.terminal.bundleIdentifier) == (.paste, .singleLine))
        // Chrome is built in as Paste, but the user's Accessibility setting is what applies now.
        #expect(model.currentSettings(for: Self.chrome.bundleIdentifier) == (.accessibility, .multiLine))
    }

    @Test func aLineSettingAloneIsASetting() async throws {
        let folder = EditableListTemporaryFolder()
        defer { folder.cleanUp() }
        let catalog = FakeAppCatalog(installed: [Self.notes, Self.bbedit], running: [Self.notes, Self.bbedit])
        let (model, store) = makeModel(in: folder, catalog: catalog)
        await model.load()

        var draft = model.newDraft()
        draft.app = Self.bbedit
        #expect(model.validation(of: draft) == .incomplete("Choose a setting BBEdit doesn\u{2019}t already use."))
        draft.lineMode = .singleLine
        #expect(model.validation(of: draft) == .valid)
        #expect(await model.save(draft))

        #expect(try await store.load() == AppOverrides(
            methods: ["com.barebones.bbedit": .accessibility], lines: ["com.barebones.bbedit": .singleLine]
        ))
        #expect(model.userRows.map(\.lineMode) == [.singleLine])
        model.refreshRunningApps()
        #expect(model.runningApps == [Self.notes])
    }

    /// A file from before line settings: the row shows the line setting that applies, and saving
    /// stores it.
    @Test func anEntryWithOnlyAMethodShowsTheLineSettingThatApplies() async throws {
        let folder = EditableListTemporaryFolder()
        defer { folder.cleanUp() }
        let (model, store) = makeModel(in: folder)
        try folder.write(#"{"methods": {"com.apple.Terminal": "accessibility", "com.apple.Notes": "paste"}}"#, to: Self.fileName)
        await model.load()

        #expect(model.userRows.map(\.lineMode) == [.multiLine, .singleLine], "Notes, then Terminal")
        let terminal = try #require(model.userRows.first { $0.bundleIdentifier == "com.apple.Terminal" })
        #expect(await model.save(model.draft(for: terminal)))
        #expect(try await store.load().lines == ["com.apple.Terminal": .singleLine])
    }

    @Test func runningAppsLeaveOutAppsWithASettingAndRepeats() async throws {
        let folder = EditableListTemporaryFolder()
        defer { folder.cleanUp() }
        let catalog = FakeAppCatalog(installed: [Self.terminal, Self.notes], running: [Self.notes, Self.terminal, Self.bbedit, Self.notes])
        let (model, store) = makeModel(in: folder, catalog: catalog)
        try await store.save(AppOverrides(methods: ["com.apple.terminal": .accessibility]))
        await model.load()

        model.refreshRunningApps()

        #expect(model.runningApps.map(\.name) == ["BBEdit", "Notes"])
    }

    @Test func addingAnAppSavesOnlyThatApp() async throws {
        let folder = EditableListTemporaryFolder()
        defer { folder.cleanUp() }
        let (model, store) = makeModel(in: folder)
        await model.load()

        var draft = model.newDraft()
        #expect(model.validation(of: draft) == .incomplete("Choose an app."))
        draft.app = Self.bbedit
        draft.method = .paste
        #expect(await model.save(draft))

        #expect(try await store.load() == AppOverrides(
            methods: ["com.barebones.bbedit": .paste], lines: ["com.barebones.bbedit": .multiLine]
        ))
        #expect(model.userRows.map(\.bundleIdentifier) == ["com.barebones.bbedit"])
    }

    @Test func aSecondSettingForTheSameAppIsInvalidAndTheFileIsUntouched() async throws {
        let folder = EditableListTemporaryFolder()
        defer { folder.cleanUp() }
        let (model, store) = makeModel(in: folder)
        try await store.save(AppOverrides(methods: ["com.barebones.bbedit": .paste]))
        await model.load()
        let before = folder.contents(of: Self.fileName)

        let duplicate = AppOverrideDraft(app: Self.bbedit, method: .accessibility, lineMode: .singleLine, isNew: true)

        #expect(model.validation(of: duplicate) == .invalid("You already have a setting for BBEdit. Edit it instead."))
        #expect(!(await model.save(duplicate)))
        #expect(folder.contents(of: Self.fileName) == before)
    }

    @Test func aChangeKeepsEntriesAddedToTheFileSinceItWasRead() async throws {
        let folder = EditableListTemporaryFolder()
        defer { folder.cleanUp() }
        let (model, store) = makeModel(in: folder)
        await model.load()
        try await store.save(AppOverrides(methods: ["org.example.HandEdited": .paste]))

        #expect(await model.save(AppOverrideDraft(app: Self.notes, method: .paste, lineMode: .multiLine, isNew: true)))

        #expect(try await store.load() == AppOverrides(
            methods: ["org.example.HandEdited": .paste, "com.apple.Notes": .paste], lines: ["com.apple.Notes": .multiLine]
        ))
    }

    @Test func savingReplacesAnEntryForTheSameAppInAnotherCasing() async throws {
        let folder = EditableListTemporaryFolder()
        defer { folder.cleanUp() }
        let (model, store) = makeModel(in: folder)
        // A hand-edited file can name one app twice; Launch Services ignores the case.
        try await store.save(AppOverrides(
            methods: ["com.apple.Notes": .accessibility, "COM.APPLE.NOTES": .accessibility],
            lines: ["com.apple.notes": .singleLine]
        ))
        await model.load()
        let row = try #require(model.userRows.first { $0.bundleIdentifier == "com.apple.Notes" })
        #expect(row.app.name == "Notes")
        #expect(model.userRows.first { $0.bundleIdentifier == "COM.APPLE.NOTES" }?.app.isInstalled == false)

        var edit = model.draft(for: row)
        edit.method = .paste
        #expect(await model.save(edit))

        #expect(try await store.load() == AppOverrides(
            methods: ["com.apple.Notes": .paste], lines: ["com.apple.Notes": .singleLine]
        ))
        #expect(model.userRows.map(\.bundleIdentifier) == ["com.apple.Notes"])
    }

    @Test func aRowKeepsTheIdentifierAsStoredEvenWhenTheAppIsFound() async throws {
        let folder = EditableListTemporaryFolder()
        defer { folder.cleanUp() }
        let catalog = FakeAppCatalog(installed: [])
        // Launch Services finds the app whatever the case, and reports its own spelling.
        catalog.installed["com.barebones.BBEdit"] = Self.bbedit
        let (model, store) = makeModel(in: folder, catalog: catalog)
        try await store.save(AppOverrides(methods: ["com.barebones.BBEdit": .paste]))
        await model.load()

        let row = try #require(model.userRows.first)
        #expect(row.app.name == "BBEdit")
        #expect(row.app.bundleIdentifier == "com.barebones.BBEdit")
        #expect(await model.delete(bundleIdentifier: row.bundleIdentifier))
        #expect(try await store.load() == .empty)
    }

    @Test func removingASettingLeavesTheOthers() async throws {
        let folder = EditableListTemporaryFolder()
        defer { folder.cleanUp() }
        let (model, store) = makeModel(in: folder)
        try await store.save(AppOverrides(
            methods: ["com.apple.Terminal": .accessibility, "com.apple.Notes": .paste],
            lines: ["com.apple.Terminal": .multiLine, "com.apple.Notes": .singleLine]
        ))
        await model.load()

        #expect(await model.delete(bundleIdentifier: "com.apple.Terminal"))

        #expect(try await store.load() == AppOverrides(methods: ["com.apple.Notes": .paste], lines: ["com.apple.Notes": .singleLine]))
        #expect(model.builtInRows.allSatisfy { !$0.isReplacedByUser })
    }

    /// The change runs inside the store's update, so removing a setting that another window
    /// already removed writes nothing, and an entry this version skipped stays in the file.
    @Test func removingASettingThatIsAlreadyGoneLeavesTheFileAlone() async throws {
        let folder = EditableListTemporaryFolder()
        defer { folder.cleanUp() }
        let (model, _) = makeModel(in: folder)
        try folder.write(#"{"methods": {"com.apple.Notes": "paste", "org.example.Future": "dictate"}}"#, to: Self.fileName)
        await model.load()
        try folder.write(#"{"methods": {"org.example.Future": "dictate"}}"#, to: Self.fileName)
        let before = folder.contents(of: Self.fileName)

        #expect(await model.delete(bundleIdentifier: "com.apple.Notes"))

        #expect(folder.contents(of: Self.fileName) == before)
        #expect(model.userRows.isEmpty)
    }

    @Test func anAppWithoutABundleIdentifierCannotBeChosen() async {
        let folder = EditableListTemporaryFolder()
        defer { folder.cleanUp() }
        let catalog = FakeAppCatalog(installed: [])
        let known = URL(fileURLWithPath: "/Applications/BBEdit.app")
        catalog.bundles[known] = Self.bbedit
        let (model, _) = makeModel(in: folder, catalog: catalog)

        #expect(model.chosenApp(at: URL(fileURLWithPath: "/Applications/Broken.app")) == nil)
        #expect(model.chosenApp(at: known) == Self.bbedit)
    }

    @Test func aDamagedFileIsSetAsideAndReported() async throws {
        let folder = EditableListTemporaryFolder()
        defer { folder.cleanUp() }
        let (model, _) = makeModel(in: folder)
        try folder.write("{\"methods\": [1, 2]}", to: Self.fileName)

        await model.load()

        let backupName = "\(Self.fileName).corrupt-\(EditableListTemporaryFolder.backupStamp)"
        #expect(model.status.loadState == .loaded)
        #expect(model.userRows.isEmpty)
        #expect(model.status.recoveredBackup?.lastPathComponent == backupName)
        #expect(try folder.names() == [backupName])
    }

    @Test func anUnreadableFileFailsAndNothingOverwritesIt() async throws {
        let folder = EditableListTemporaryFolder()
        defer { folder.cleanUp() }
        let (model, _) = makeModel(in: folder)
        try folder.makeUnreadable(Self.fileName)

        await model.load()

        guard case .failed(let message) = model.status.loadState else {
            Issue.record("Expected the load to fail, got \(model.status.loadState)")
            return
        }
        #expect(message.hasPrefix("The per-app settings could not be read"))
        #expect(!(await model.save(AppOverrideDraft(app: Self.notes, method: .paste, lineMode: .multiLine, isNew: true))))
        #expect(!(await model.delete(bundleIdentifier: "com.apple.Notes")))
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: folder.file(Self.fileName).path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)

        try folder.makeReadable(Self.fileName)
        await model.load()
        #expect(model.status.loadState == .loaded)
    }

    @Test func everyMethodHasASummary() {
        for method in InsertionMethod.allCases {
            #expect(!AppOverrideMethodText.summary(method).isEmpty)
        }
    }

    @Test func everyLineSettingHasASummary() {
        for mode in LineMode.allCases {
            #expect(!AppOverrideLineText.summary(mode).isEmpty)
        }
    }

    @Test func theNoteCountsTheBuiltInSettingsThatArentListed() {
        #expect(AppOverrideBuiltInText.uninstalledNote(uninstalled: 0, listed: 3) == nil)
        #expect(AppOverrideBuiltInText.uninstalledNote(uninstalled: 1, listed: 2)
            == "1 more app has a built-in setting that applies once it\u{2019}s installed.")
        #expect(AppOverrideBuiltInText.uninstalledNote(uninstalled: 15, listed: 3)
            == "15 more apps have a built-in setting that applies once they\u{2019}re installed.")
        // With none listed above it, there is nothing for "more" to add to.
        #expect(AppOverrideBuiltInText.uninstalledNote(uninstalled: 18, listed: 0)
            == "18 apps have a built-in setting that applies once they\u{2019}re installed.")
    }
}
