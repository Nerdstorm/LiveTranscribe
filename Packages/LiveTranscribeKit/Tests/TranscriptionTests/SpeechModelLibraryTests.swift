import Foundation
import HuggingFace
import os
import Testing
@testable import Transcription

/// Settings › Models' library of the catalog's models, over a disk and a network faked in memory.
@MainActor
@Suite("Speech model library")
struct SpeechModelLibraryTests {
    private let small = model("owner/small")
    private let large = model("owner/large")

    private func library(_ downloads: FakeDownloads) -> SpeechModelLibrary {
        SpeechModelLibrary(catalog: SpeechModelCatalog(models: [small, large]), downloads: downloads)
    }

    @Test func modelsOnDiskAreDownloadedAndCanBeRemoved() {
        let downloads = FakeDownloads(downloaded: ["owner/small"])
        let library = library(downloads)
        #expect(library.state(of: small) == .downloaded)
        #expect(library.state(of: large) == .notDownloaded)
        #expect(library.canRemove(small))
        #expect(!library.canRemove(large))
    }

    @Test func aDownloadReportsItsProgressThenIsDownloaded() async throws {
        let downloads = FakeDownloads()
        let library = library(downloads)
        library.download(large)
        #expect(library.state(of: large) == .downloading(fraction: 0))
        #expect(!library.canRemove(large), "not while it downloads")

        try await eventually { library.state(of: large) == .downloaded }
        #expect(downloads.progressReported == [0.5, 1])
        #expect(library.canRemove(large))
    }

    @Test func aFailedDownloadSaysWhyUntilItsTriedAgain() async throws {
        let downloads = FakeDownloads(failure: URLError(.notConnectedToInternet))
        let library = library(downloads)
        library.download(large)
        try await eventually { if case .failed = library.state(of: large) { true } else { false } }
        guard case .failed(let message) = library.state(of: large) else { return }
        #expect(message == URLError(.notConnectedToInternet).localizedDescription)

        library.refresh()
        #expect(library.state(of: large) == .failed(message), "a look at the disk keeps the failure")

        downloads.failure = nil
        library.download(large)
        try await eventually { library.state(of: large) == .downloaded }
    }

    @Test func aCancelledDownloadIsNotDownloaded() async throws {
        let downloads = FakeDownloads(hangs: true)
        let library = library(downloads)
        library.download(large)
        try await eventually { downloads.started == ["owner/large"] }
        library.cancelDownload(large)
        try await eventually { library.state(of: large) == .notDownloaded }
    }

    @Test func removingAModelLeavesItNotDownloaded() {
        let downloads = FakeDownloads(downloaded: ["owner/small"])
        let library = library(downloads)
        library.remove(small)
        #expect(library.state(of: small) == .notDownloaded)
        #expect(!library.canRemove(small))
        #expect(library.removalError == nil)
    }

    @Test func aRemovalThatFailsSaysSo() {
        let downloads = FakeDownloads(downloaded: ["owner/small"])
        downloads.removalFailure = CocoaError(.fileWriteNoPermission)
        let library = library(downloads)
        library.remove(small)
        #expect(library.state(of: small) == .downloaded)
        #expect(library.removalError?.hasPrefix("small couldn't be removed:") == true)
    }

    @Test func aLookAtTheDiskFindsModelsDownloadedSince() {
        let downloads = FakeDownloads()
        let library = library(downloads)
        #expect(library.state(of: small) == .notDownloaded)
        downloads.markDownloaded("owner/small")
        library.refresh()
        #expect(library.state(of: small) == .downloaded)
    }

    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(condition(), "timed out")
    }
}

private func model(_ repository: Repo.ID) -> SpeechModelCatalog.Model {
    SpeechModelCatalog.Model(
        id: repository.name, name: repository.name, summary: "", languages: "", licence: "MIT", credit: "",
        mac: .init(repository: repository, revision: String(repeating: "c", count: 40), bytes: 1, kind: "whisper")
    )
}

/// Models on a disk and a network in memory: a download reports half, then all, and lands.
private final class FakeDownloads: SpeechModelDownloading, @unchecked Sendable {
    // @unchecked: every field is behind the lock.
    private struct State {
        var downloaded: Set<String>
        var failure: Error?
        var removalFailure: Error?
        var started: [String] = []
        var progress: [Double] = []
    }

    private let state: OSAllocatedUnfairLock<State>
    private let hangs: Bool

    init(downloaded: Set<String> = [], failure: Error? = nil, hangs: Bool = false) {
        state = OSAllocatedUnfairLock(uncheckedState: State(downloaded: downloaded, failure: failure))
        self.hangs = hangs
    }

    var failure: Error? {
        get { state.withLockUnchecked { $0.failure } }
        set { state.withLockUnchecked { $0.failure = newValue } }
    }

    var removalFailure: Error? {
        get { state.withLockUnchecked { $0.removalFailure } }
        set { state.withLockUnchecked { $0.removalFailure = newValue } }
    }

    var started: [String] { state.withLockUnchecked { $0.started } }
    var progressReported: [Double] { state.withLockUnchecked { $0.progress } }

    func markDownloaded(_ repository: String) {
        state.withLockUnchecked { _ = $0.downloaded.insert(repository) }
    }

    func folder(for model: SpeechModelCatalog.Model) -> URL? {
        state.withLockUnchecked { $0.downloaded.contains(model.mac.repository.rawValue) }
            ? URL(fileURLWithPath: "/models/\(model.mac.repository.rawValue)") : nil
    }

    func hasFiles(of model: SpeechModelCatalog.Model) -> Bool {
        folder(for: model) != nil
    }

    func download(_ model: SpeechModelCatalog.Model, progress: @escaping @MainActor @Sendable (Double) -> Void) async throws -> URL {
        let repository = model.mac.repository.rawValue
        let failure = state.withLockUnchecked { state -> Error? in
            state.started.append(repository)
            return state.failure
        }
        if hangs { try await Task.sleep(for: .seconds(30)) }
        if let failure { throw failure }
        for fraction in [0.5, 1] {
            state.withLockUnchecked { $0.progress.append(fraction) }
            await progress(fraction)
        }
        markDownloaded(repository)
        return URL(fileURLWithPath: "/models/\(repository)")
    }

    func remove(_ model: SpeechModelCatalog.Model) throws {
        if let failure = removalFailure { throw failure }
        state.withLockUnchecked { _ = $0.downloaded.remove(model.mac.repository.rawValue) }
    }
}
