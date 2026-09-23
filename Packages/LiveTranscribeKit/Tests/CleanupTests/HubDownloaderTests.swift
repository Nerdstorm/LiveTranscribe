@testable import Cleanup
import Foundation
import HuggingFace
import Testing

@Suite("HubDownloader")
struct HubDownloaderTests {
    private let repo = Repo.ID(rawValue: "mlx-community/Qwen3-1.7B-4bit")!
    private let commit = "0123456789abcdef0123456789abcdef01234567"

    /// A throwaway Hugging Face cache whose `main` ref points at `commit`.
    private func downloader() throws -> (HubDownloader, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HubDownloaderTests-\(UUID().uuidString)")
        let cache = HubCache(cacheDirectory: directory)
        let refs = cache.refsDirectory(repo: repo, kind: .model)
        try FileManager.default.createDirectory(at: refs, withIntermediateDirectories: true)
        try commit.write(to: refs.appendingPathComponent("main"), atomically: true, encoding: .utf8)
        return (HubDownloader(client: HubClient(cache: cache)), directory)
    }

    @Test func cachedBranchResolvesToItsCommitSoNoNetworkIsNeeded() throws {
        let (downloader, directory) = try downloader()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(downloader.resolvedRevision("main", of: repo, useLatest: false) == commit)
    }

    @Test func askingForTheLatestKeepsTheBranch() throws {
        let (downloader, directory) = try downloader()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(downloader.resolvedRevision("main", of: repo, useLatest: true) == "main")
    }

    @Test func uncachedBranchesAndCommitsAreLeftAlone() throws {
        let (downloader, directory) = try downloader()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(downloader.resolvedRevision("dev", of: repo, useLatest: false) == "dev")
        #expect(downloader.resolvedRevision(commit, of: repo, useLatest: false) == commit)
    }
}
