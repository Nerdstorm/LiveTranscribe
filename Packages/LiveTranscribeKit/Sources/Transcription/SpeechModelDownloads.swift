import Foundation
import HuggingFace
import Shared

/// The catalog's models on this Mac: whether each is downloaded, downloading one, and removing
/// one.
///
/// A catalog model is downloaded into the Hugging Face cache at its pinned commit, and loaded
/// from its snapshot there (`models--<owner>--<name>/snapshots/<commit>`), so a new pin downloads
/// the new commit. A repository entered by hand is downloaded by mlx-audio-swift instead, which
/// copies the snapshot into `mlx-audio/<owner>_<name>` beside the cache (an APFS clone, which takes
/// no more space) and uses that copy from then on, whatever the repository has since. Versions
/// before the catalog made such copies of catalog models too: ``olderCopy(of:)``.
public struct SpeechModelDownloads: Sendable {
    /// The files a download fetches: those mlx-audio-swift fetches for any model, and every kind's
    /// extra files.
    static let patterns = ["*.safetensors", "*.json", "*.txt", "*.wav"] + SpeechModelKind.downloadPatterns

    private let cache: HubCache

    public init(cache: HubCache = .default) {
        self.cache = cache
    }

    /// The model's folder if it's downloaded: its snapshot at the pinned commit, with config.json
    /// and all of its weights.
    public func folder(for model: SpeechModelCatalog.Model) -> URL? {
        guard let snapshot = try? cache.snapshotPath(repo: model.mac.repository, kind: .model, commitHash: model.mac.revision),
              (try? SpeechModelKind.of(folder: snapshot, name: model.mac.repository.name)) != nil
        else { return nil }
        return snapshot
    }

    /// Downloads the model at its pinned commit, or finds it downloaded, and returns its folder.
    ///
    /// The download also records the snapshot's file list, so loading it again needs no network.
    /// Files already in the cache at that commit are not downloaded again.
    ///
    /// - Parameter progress: the fraction downloaded, on the main actor.
    public func download(
        _ model: SpeechModelCatalog.Model,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> URL {
        if let folder = folder(for: model) { return folder }
        let started = ContinuousClock.now
        let snapshot = try await HubClient(cache: cache).downloadSnapshot(
            of: model.mac.repository,
            kind: .model,
            revision: model.mac.revision,
            matching: Self.patterns,
            progressHandler: { fileProgress in progress(fileProgress.fractionCompleted) }
        )
        try Task.checkCancellation()
        // A snapshot without its config or every weight file isn't the model.
        _ = try SpeechModelKind.of(folder: snapshot, name: model.mac.repository.name)
        Log.transcription.info(
            "Downloaded \(model.mac.repository.rawValue, privacy: .public) at \(model.mac.revision.prefix(7), privacy: .public) in \(started.duration(to: .now).wholeMilliseconds) ms"
        )
        return snapshot
    }

    /// The copy of the model's repository that a version before the catalog downloaded, which
    /// works when the pinned commit can't be downloaded (offline, say).
    public func olderCopy(of model: SpeechModelCatalog.Model) -> URL? {
        let folder = olderCopyFolder(of: model.mac.repository)
        guard (try? SpeechModelKind.of(folder: folder, name: model.mac.repository.name)) != nil else { return nil }
        return folder
    }

    /// Whether any copy of the model is on this Mac, to remove.
    public func hasFiles(of model: SpeechModelCatalog.Model) -> Bool {
        foldersToRemove(for: model).contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Removes every copy of the model: its Hugging Face cache folder, every commit in it, and
    /// the older copy.
    public func remove(_ model: SpeechModelCatalog.Model) throws {
        for folder in foldersToRemove(for: model) where FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }
        Log.transcription.info("Removed \(model.mac.repository.rawValue, privacy: .public)")
    }

    private func foldersToRemove(for model: SpeechModelCatalog.Model) -> [URL] {
        [cache.repoDirectory(repo: model.mac.repository, kind: .model), olderCopyFolder(of: model.mac.repository)]
    }

    /// Where mlx-audio-swift keeps its copy of a repository.
    private func olderCopyFolder(of repository: Repo.ID) -> URL {
        cache.cacheDirectory
            .appendingPathComponent("mlx-audio")
            .appendingPathComponent(repository.rawValue.replacingOccurrences(of: "/", with: "_"))
    }
}
