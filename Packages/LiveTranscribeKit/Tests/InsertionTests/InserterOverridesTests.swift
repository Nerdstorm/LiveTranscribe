import Foundation
import Insertion
import Testing

@Suite("InserterOverrides")
struct InserterOverridesTests {
    @Test("Terminals, Electron and Chromium apps paste by default", arguments: [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
        "io.alacritty", "net.kovidgoyal.kitty", "com.github.wez.wezterm",
        "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.tinyspeck.slackmacgap", "com.hnc.Discord",
        "notion.id", "com.figma.Desktop", "com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac",
        "company.thebrowser.Browser", "com.anthropic.claudefordesktop",
    ])
    func bundledAppsPaste(bundleIdentifier: String) {
        #expect(InserterOverrides.bundled.method(for: bundleIdentifier) == .paste)
    }

    @Test func bundledListHasNothingElse() {
        #expect(InserterOverrides.bundled.methods.count == 18)
        #expect(InserterOverrides.bundled.method(for: "com.apple.TextEdit") == nil)
    }

    @Test func theUserWinsWhenMerging() {
        let user = InserterOverrides(methods: ["com.apple.Terminal": .accessibility, "com.apple.Notes": .paste])
        let merged = InserterOverrides.bundled.merged(with: user)
        #expect(merged.method(for: "com.apple.Terminal") == .accessibility)
        #expect(merged.method(for: "com.apple.Notes") == .paste)
        #expect(merged.method(for: "com.google.Chrome") == .paste)
        #expect(merged.methods.count == 19)
    }

    @Test func lookupIgnoresCaseButPrefersAnExactMatch() {
        let overrides = InserterOverrides(methods: ["com.example.App": .paste, "COM.EXAMPLE.APP": .accessibility])
        #expect(overrides.method(for: "com.example.App") == .paste)
        #expect(overrides.method(for: "COM.EXAMPLE.APP") == .accessibility)
        #expect(overrides.method(for: "Com.Example.App") == .accessibility)
        #expect(overrides.method(for: nil) == nil)
    }

    @Test func encodesAsABundleIdentifierMap() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(InserterOverrides(methods: ["com.apple.Notes": .paste]))
        #expect(String(decoding: data, as: UTF8.self) == #"{"methods":{"com.apple.Notes":"paste"}}"#)
        #expect(try JSONDecoder().decode(InserterOverrides.self, from: data).methods == ["com.apple.Notes": .paste])
    }
}

@Suite("InserterOverridesStore")
struct InserterOverridesStoreTests {
    /// A fresh folder per test, removed afterwards.
    final class TemporaryFolder {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("InserterOverridesStoreTests-\(UUID().uuidString)", isDirectory: true)

        var fileURL: URL { url.appendingPathComponent(InserterOverridesStore.fileName) }

        func contents() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
        }

        deinit {
            try? FileManager.default.removeItem(at: url)
        }
    }

    @Test func aMissingFileMeansNoOverrides() async throws {
        let folder = TemporaryFolder()
        #expect(try await InserterOverridesStore(fileURL: folder.fileURL).load() == .empty)
    }

    @Test func savesAndLoadsTheUserEntries() async throws {
        let folder = TemporaryFolder()
        let store = InserterOverridesStore(fileURL: folder.fileURL)
        let user = InserterOverrides(methods: ["com.apple.Notes": .paste, "com.apple.Terminal": .accessibility])

        try await store.save(user)

        #expect(try await store.load() == user)
        #expect(try folder.contents() == [InserterOverridesStore.fileName])
    }

    static let fixedNow = Date(timeIntervalSince1970: 1_790_000_000) // 2026-09-21T14:13:20Z
    static let corruptName = "insertion-overrides.json.corrupt-20260921T141320Z"

    @Test("A corrupt file is set aside and read as empty", arguments: [
        "not json",
        "[]",
        "{}",
        #"{"methods":{"com.apple.Notes":1}}"#,
        #"{"methods":["com.apple.Notes"]}"#,
    ])
    func aCorruptFileIsSetAside(contents: String) async throws {
        let folder = TemporaryFolder()
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: folder.fileURL)
        let store = InserterOverridesStore(fileURL: folder.fileURL, now: { Self.fixedNow })

        #expect(try await store.load() == .empty)
        #expect(try folder.contents() == [Self.corruptName])
        #expect(try Data(contentsOf: folder.url.appendingPathComponent(Self.corruptName)) == Data(contents.utf8))

        // The next save starts a fresh file and leaves the corrupt one for inspection.
        try await store.save(InserterOverrides(methods: ["com.apple.Notes": .paste]))
        #expect(try folder.contents() == [Self.corruptName, InserterOverridesStore.fileName].sorted())
    }

    @Test func aSecondCorruptFileInTheSameSecondDoesNotReplaceTheFirst() async throws {
        let folder = TemporaryFolder()
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        let earlier = folder.url.appendingPathComponent(Self.corruptName)
        try Data("earlier".utf8).write(to: earlier)
        try Data("later".utf8).write(to: folder.fileURL)
        let store = InserterOverridesStore(fileURL: folder.fileURL, now: { Self.fixedNow })

        #expect(try await store.load() == .empty)
        #expect(try folder.contents() == [Self.corruptName, Self.corruptName + "-2"])
        #expect(try Data(contentsOf: earlier) == Data("earlier".utf8))
    }

    /// Nothing is lost silently: a corrupt file that cannot be renamed is an error, and stays put.
    @Test(.enabled(if: getuid() != 0, "root ignores the read-only folder"))
    func aCorruptFileThatCannotBeSetAsideIsAnError() async throws {
        let folder = TemporaryFolder()
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: folder.fileURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.url.path) }
        let store = InserterOverridesStore(fileURL: folder.fileURL, now: { Self.fixedNow })

        await #expect {
            try await store.load()
        } throws: { error in
            guard case .readFailed = error as? InserterOverridesStoreError else { return false }
            return true
        }
        #expect(try folder.contents() == [InserterOverridesStore.fileName])
    }

    /// A typo or a method from a newer version costs that one entry, not the whole file.
    @Test func anUnknownMethodSkipsOnlyThatEntry() async throws {
        let folder = TemporaryFolder()
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        try Data(#"""
            {"methods":{"com.apple.Notes":"type","com.apple.Terminal":"Accessibility","com.google.Chrome":"paste"}}
            """#.utf8).write(to: folder.fileURL)
        let store = InserterOverridesStore(fileURL: folder.fileURL)

        #expect(try await store.load() == InserterOverrides(
            methods: ["com.apple.Terminal": .accessibility, "com.google.Chrome": .paste]
        ))
        #expect(try folder.contents() == [InserterOverridesStore.fileName])
    }

    @Test func anUnreadableFileIsAnErrorAndIsLeftAlone() async throws {
        let folder = TemporaryFolder()
        // A folder where the file should be: it exists but cannot be read as data.
        try FileManager.default.createDirectory(at: folder.fileURL, withIntermediateDirectories: true)
        let store = InserterOverridesStore(fileURL: folder.fileURL)

        await #expect {
            try await store.load()
        } throws: { error in
            guard case .readFailed = error as? InserterOverridesStoreError else { return false }
            return (error as? LocalizedError)?.errorDescription?.isEmpty == false
        }
        #expect(try folder.contents() == [InserterOverridesStore.fileName])
    }

    @Test func aFailedSaveIsReported() async throws {
        let folder = TemporaryFolder()
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        // A file where the parent folder should be.
        let blocker = folder.url.appendingPathComponent("blocker")
        try Data().write(to: blocker)
        let store = InserterOverridesStore(fileURL: blocker.appendingPathComponent(InserterOverridesStore.fileName))

        await #expect {
            try await store.save(.bundled)
        } throws: { error in
            guard case .writeFailed = error as? InserterOverridesStoreError else { return false }
            return true
        }
    }

    @Test func theDefaultLocationIsInApplicationSupport() throws {
        let url = try InserterOverridesStore.defaultFileURL(bundleIdentifier: "org.nerdstorm.LiveTranscribe")
        #expect(url.lastPathComponent == "insertion-overrides.json")
        #expect(url.deletingLastPathComponent().lastPathComponent == "org.nerdstorm.LiveTranscribe")
        #expect(url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "Application Support")
    }
}
