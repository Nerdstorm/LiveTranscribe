import Foundation
import Snippets

/// A ``SnippetStore`` in a fresh, not yet created folder under the temporary directory, so store
/// tests can run in parallel without seeing each other's files. Call ``cleanUp()`` when done.
struct TemporaryStore {
    /// 2026-09-21 14:13:20 UTC: names the backup of a damaged file predictably.
    static let fixedDate = Date(timeIntervalSince1970: 1_790_000_000)
    /// The backup name that ``fixedDate`` produces.
    static let backupName = "snippets.json.corrupt-20260921T141320Z"

    /// Permission tests make a folder read-only; the superuser writes into it regardless.
    static let honoursPermissions = getuid() != 0

    let store: SnippetStore
    /// The whole temporary tree, standing in for Application Support.
    let root: URL

    init() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveTranscribeTests-\(UUID().uuidString)", isDirectory: true)
        let url = SnippetStore.defaultURL(applicationSupport: root, bundleIdentifier: "org.example.Test")
        store = SnippetStore(fileURL: url, now: { Self.fixedDate })
    }

    var fileURL: URL { store.fileURL }
    /// The folder that holds `snippets.json`.
    var folder: URL { store.fileURL.deletingLastPathComponent() }

    /// Writes `data` where the store keeps its file, creating the folder, as a hand edit would.
    func writeFile(_ data: Data) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: fileURL)
    }

    func folderContents() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    func permissions(of url: URL) throws -> Int? {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue
    }

    func setPermissions(_ permissions: Int, of url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    func cleanUp() {
        try? setPermissions(0o700, of: folder)
        try? FileManager.default.removeItem(at: root)
    }
}

extension SnippetError {
    /// Whether `error` is a read failure, whatever its message.
    static func isReadFailure(_ error: SnippetError?) -> Bool {
        if case .readFailed? = error { return true }
        return false
    }

    /// Whether `error` is a write failure, whatever its message.
    static func isWriteFailure(_ error: SnippetError?) -> Bool {
        if case .writeFailed? = error { return true }
        return false
    }
}

/// Snippets the store tests save and read back.
enum StoreFixtures {
    static let calendar = Snippet(trigger: "my calendar link", expansion: "https://cal.example.com/alex")
    static let signature = Snippet(trigger: "sign off", expansion: "Best,\nAlex \u{1F44B}")
}
