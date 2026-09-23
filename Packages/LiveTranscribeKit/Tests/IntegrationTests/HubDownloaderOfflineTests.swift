@testable import Cleanup
import Foundation
import HuggingFace
import Shared
import Testing

@Suite(
    "Cleanup model downloads",
    .tags(.models),
    .enabled(
        if: ProcessInfo.processInfo.environment["LT_RUN_MODEL_TESTS"] == "1",
        "set LT_RUN_MODEL_TESTS=1 (TEST_RUNNER_LT_RUN_MODEL_TESTS=1 with xcodebuild)"
    )
)
struct HubDownloaderOfflineTests {
    /// Downloads one small file of the cleanup model from its branch, as the first launch does,
    /// then loads it again with every request failing, as the next launch would offline.
    @Test(.timeLimit(.minutes(5)))
    func theLaunchAfterTheFirstDownloadMakesNoRequests() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HubDownloaderOffline-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = HubCache(cacheDirectory: directory)
        let id = AppSettings.defaults.llmModel
        let files = ["config.json"]

        _ = try await HubDownloader(client: HubClient(cache: cache))
            .download(id: id, revision: nil, matching: files, useLatest: false, progressHandler: { _ in })

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineURLProtocol.self]
        let offline = HubDownloader(client: HubClient(session: URLSession(configuration: configuration), cache: cache))
        let snapshot = try await offline
            .download(id: id, revision: nil, matching: files, useLatest: false, progressHandler: { _ in })

        #expect(OfflineURLProtocol.requests.isEmpty, "requests made: \(OfflineURLProtocol.requests)")
        #expect(FileManager.default.fileExists(atPath: snapshot.appendingPathComponent("config.json").path))
    }
}

/// Fails every request, as if the Mac were offline, and records it.
private final class OfflineURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var recorded: [URL] = []

    static var requests: [URL] { lock.withLock { recorded } }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let url = request.url {
            Self.lock.withLock { Self.recorded.append(url) }
        }
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override func stopLoading() {}
}
