@testable import DictationUI
import Foundation
import Testing

/// Reading an app bundle chosen in the Open panel, with fake `.app` folders on disk.
@Suite("SystemAppOverrideAppCatalog")
@MainActor
struct AppOverrideAppCatalogTests {
    /// Writes `<name>.app/Contents/Info.plist` with `info` and returns the bundle's URL.
    private func makeBundle(named name: String, info: [String: String], in folder: EditableListTemporaryFolder) throws -> URL {
        let bundle = folder.url.appendingPathComponent("\(name).app", isDirectory: true)
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        return bundle
    }

    @Test func aBundlesDisplayNameIsPreferred() throws {
        let folder = EditableListTemporaryFolder()
        defer { folder.cleanUp() }
        let url = try makeBundle(
            named: "Fake",
            info: ["CFBundleIdentifier": "org.example.fake", "CFBundleName": "Fake", "CFBundleDisplayName": "Fake Editor"],
            in: folder
        )

        let app = SystemAppOverrideAppCatalog().app(at: url)

        #expect(app == AppOverrideApp(bundleIdentifier: "org.example.fake", name: "Fake Editor", url: url))
    }

    @Test func withoutNamesTheFileNameIsUsed() throws {
        let folder = EditableListTemporaryFolder()
        defer { folder.cleanUp() }
        let url = try makeBundle(named: "Plain Tool", info: ["CFBundleIdentifier": "org.example.plain"], in: folder)

        #expect(SystemAppOverrideAppCatalog().app(at: url)?.name == "Plain Tool")
    }

    @Test func aBundleWithoutAnIdentifierIsNotAnApp() throws {
        let folder = EditableListTemporaryFolder()
        defer { folder.cleanUp() }
        let url = try makeBundle(named: "Anonymous", info: ["CFBundleName": "Anonymous"], in: folder)

        #expect(SystemAppOverrideAppCatalog().app(at: url) == nil)
    }

    @Test func anUnknownIdentifierIsNotInstalled() {
        #expect(SystemAppOverrideAppCatalog().app(bundleIdentifier: "org.example.does-not-exist-\(UUID().uuidString)") == nil)
    }
}
