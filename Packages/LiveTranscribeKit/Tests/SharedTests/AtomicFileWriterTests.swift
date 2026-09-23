import Foundation
@testable import Shared
import Testing

@Suite("AtomicFileWriter")
struct AtomicFileWriterTests {
    private let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "AtomicFileWriterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private func permissions(of url: URL) throws -> Int {
        try (FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private func leftovers() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".tmp") }
    }

    @Test func writesTheDataWithExactlyThePermissions() throws {
        let file = folder.appending(path: "notes.json")
        try AtomicFileWriter.write(Data("hello".utf8), to: file, permissions: 0o600)
        #expect(try Data(contentsOf: file) == Data("hello".utf8))
        #expect(try permissions(of: file) == 0o600)
        #expect(try leftovers().isEmpty)
    }

    @Test func replacesAnExistingFileAndItsWiderPermissions() throws {
        let file = folder.appending(path: "notes.json")
        try Data("old".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        try AtomicFileWriter.write(Data("new".utf8), to: file, permissions: 0o600)
        #expect(try Data(contentsOf: file) == Data("new".utf8))
        #expect(try permissions(of: file) == 0o600)
    }

    @Test func aFailedReplaceLeavesTheDestinationAndNoTemporaryFile() throws {
        // A directory cannot be replaced by a file, so the final rename fails.
        let destination = folder.appending(path: "occupied")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) {
            try AtomicFileWriter.write(Data("x".utf8), to: destination, permissions: 0o600)
        }
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory) && isDirectory.boolValue)
        #expect(try leftovers().isEmpty)
    }

    @Test func aMissingFolderFailsWithoutCreatingAnything() throws {
        let file = folder.appending(path: "missing/notes.json")
        #expect(throws: (any Error).self) {
            try AtomicFileWriter.write(Data("x".utf8), to: file, permissions: 0o600)
        }
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}
