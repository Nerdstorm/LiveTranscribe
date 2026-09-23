import Foundation
@testable import Persistence
import Testing

/// The chunked line reader and the atomic writer under the file-backed history.
@Suite("LineFile")
struct LineFileTests {
    private let directory = DictationHistoryFixtures.temporaryDirectory()
    private var url: URL { directory.appendingPathComponent("lines.jsonl") }

    /// Blank lines, multi-byte characters, a line longer than any chunk, and no final newline.
    private static let contents = "alpha\n\n\u{00E9}t\u{00E9} \u{6771}\u{4EAC}\nthis line is longer than every chunk size used here\n\nomega"
    private static let expectedLines = [
        "alpha", "\u{00E9}t\u{00E9} \u{6771}\u{4EAC}", "this line is longer than every chunk size used here", "omega",
    ]

    private func write(_ text: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }

    private static func strings(_ read: ((Data) throws -> Bool) throws -> Void) throws -> [String] {
        var lines: [String] = []
        try read { line in
            lines.append(String(decoding: line, as: UTF8.self))
            return true
        }
        return lines
    }

    @Test("Reads every line whatever the chunk size", arguments: [1, 2, 3, 5, 8, 13, 64, 65_536])
    func readsEveryLineWhateverTheChunkSize(chunkSize: Int) throws {
        defer { cleanUp() }
        try write(Self.contents)
        let file = LineFile(url: url, chunkSize: chunkSize)

        #expect(try Self.strings(file.forEachLine) == Self.expectedLines)
        #expect(try Self.strings(file.forEachLineReversed) == Self.expectedLines.reversed())
    }

    @Test(arguments: [1, 4, 64])
    func stopsReadingWhenAskedTo(chunkSize: Int) throws {
        defer { cleanUp() }
        try write(Self.contents)
        let file = LineFile(url: url, chunkSize: chunkSize)
        var forward: [String] = []
        var backward: [String] = []

        try file.forEachLine { forward.append(String(decoding: $0, as: UTF8.self)); return forward.count < 2 }
        try file.forEachLineReversed { backward.append(String(decoding: $0, as: UTF8.self)); return backward.count < 2 }

        #expect(forward == Array(Self.expectedLines.prefix(2)))
        #expect(backward == Array(Self.expectedLines.reversed().prefix(2)))
    }

    @Test func aMissingFileHasNoLines() throws {
        let file = LineFile(url: url, chunkSize: 16)
        #expect(try Self.strings(file.forEachLine).isEmpty)
        #expect(try Self.strings(file.forEachLineReversed).isEmpty)
    }

    @Test func appendStartsANewLineAfterATornOne() throws {
        defer { cleanUp() }
        try write("complete\ntorn")
        let file = LineFile(url: url, chunkSize: 16)

        try file.append(Data("next".utf8))

        #expect(try String(contentsOf: url, encoding: .utf8) == "complete\ntorn\nnext\n")
    }

    @Test(arguments: [1, 5, 4_096])
    func replaceSwapsInExactlyTheWrittenLines(chunkSize: Int) throws {
        defer { cleanUp() }
        try write("old one\nold two\n")
        let file = LineFile(url: url, chunkSize: chunkSize)

        try file.replace { write in
            try write(Data("new one".utf8))
            try write(Data("new two".utf8))
        }

        #expect(try String(contentsOf: url, encoding: .utf8) == "new one\nnew two\n")
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["lines.jsonl"])
    }

    @Test func aFailedReplaceLeavesTheOriginalAndNoTemporaryFile() throws {
        struct Interrupted: Error {}
        defer { cleanUp() }
        try write("original\n")
        let file = LineFile(url: url, chunkSize: 1)

        #expect(throws: Interrupted.self) {
            try file.replace { write in
                try write(Data("partial".utf8))
                throw Interrupted()
            }
        }

        #expect(try String(contentsOf: url, encoding: .utf8) == "original\n")
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["lines.jsonl"])
    }
}
