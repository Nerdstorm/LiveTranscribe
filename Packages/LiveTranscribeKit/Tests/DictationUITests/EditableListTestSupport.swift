import Foundation

/// A fresh folder under the temporary directory standing in for Application Support, so the
/// Settings list tests run against the real stores in parallel without seeing each other's files.
/// Call ``cleanUp()`` when done.
struct EditableListTemporaryFolder {
    /// 2026-09-21 14:13:20 UTC: names the backup of a damaged file predictably.
    static let fixedDate = Date(timeIntervalSince1970: 1_790_000_000)
    /// The timestamp ``fixedDate`` gives a backup's name.
    static let backupStamp = "20260921T141320Z"

    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DictationUITests-\(UUID().uuidString)", isDirectory: true)
    }

    /// Where a store in this folder keeps `name`. Nothing is created.
    func file(_ name: String) -> URL {
        url.appendingPathComponent(name, isDirectory: false)
    }

    /// Writes `text` to `name` as a hand edit would, creating the folder.
    func write(_ text: String, to name: String) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file(name))
    }

    /// The bytes of `name`, or `nil` when it doesn't exist.
    func contents(of name: String) -> Data? {
        try? Data(contentsOf: file(name))
    }

    /// Puts a folder where `name` should be, so reading it as a file fails the way an unreadable
    /// file does, without depending on permissions (which the superuser ignores).
    func makeUnreadable(_ name: String) throws {
        try FileManager.default.createDirectory(at: file(name), withIntermediateDirectories: true)
    }

    /// Undoes ``makeUnreadable(_:)``.
    func makeReadable(_ name: String) throws {
        try FileManager.default.removeItem(at: file(name))
    }

    /// The names in the folder, sorted.
    func names() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Holds a store call open, so a test can start something else while it is still running.
///
/// The code under test awaits ``pass()``; the test waits for ``waitUntilHeld()`` to know it got
/// there, does what it wants to overlap, then calls ``open()``.
@MainActor
final class EditableListTestGate {
    private var held: CheckedContinuation<Void, Never>?
    private var isOpen = false

    /// Suspends until ``open()`` is called; returns at once if it already was.
    func pass() async {
        guard !isOpen else { return }
        await withCheckedContinuation { held = $0 }
    }

    /// Lets the held call carry on, and every later one pass straight through.
    func open() {
        isOpen = true
        held?.resume()
        held = nil
    }

    /// Returns once a call is waiting in ``pass()``; `false` if none arrived after many turns.
    func waitUntilHeld() async -> Bool {
        for _ in 0..<1_000 {
            if held != nil { return true }
            await Task.yield()
        }
        return false
    }
}
