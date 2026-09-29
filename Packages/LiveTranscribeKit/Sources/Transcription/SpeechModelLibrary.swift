import Foundation
import Observation
import Shared

/// What ``SpeechModelLibrary`` needs of ``SpeechModelDownloads``: tests stand in for the disk
/// and the network with it.
public protocol SpeechModelDownloading: Sendable {
    func folder(for model: SpeechModelCatalog.Model) -> URL?
    func hasFiles(of model: SpeechModelCatalog.Model) -> Bool
    func download(_ model: SpeechModelCatalog.Model, progress: @escaping @MainActor @Sendable (Double) -> Void) async throws -> URL
    func remove(_ model: SpeechModelCatalog.Model) throws
}

extension SpeechModelDownloads: SpeechModelDownloading {}

/// The catalog's models on this Mac, for Settings › Models: which are downloaded, and
/// downloading or removing one.
///
/// The app has one, so a download carries on when Settings closes. Choosing a model is the
/// Speech-to-text setting's business, not the library's.
@MainActor
@Observable
public final class SpeechModelLibrary {
    public enum State: Equatable, Sendable {
        case notDownloaded
        case downloading(fraction: Double)
        case downloaded
        /// The last download failed, and why.
        case failed(String)
    }

    public let catalog: SpeechModelCatalog
    private var states: [SpeechModelCatalog.Model.ID: State] = [:]
    private var removable: Set<SpeechModelCatalog.Model.ID> = []
    /// Why the last removal failed; `nil` after one succeeds.
    public private(set) var removalError: String?

    @ObservationIgnored private let downloads: any SpeechModelDownloading
    @ObservationIgnored private var tasks: [SpeechModelCatalog.Model.ID: Task<Void, Never>] = [:]

    public init(catalog: SpeechModelCatalog = .bundled, downloads: any SpeechModelDownloading = SpeechModelDownloads()) {
        self.catalog = catalog
        self.downloads = downloads
        refresh()
    }

    public func state(of model: SpeechModelCatalog.Model) -> State {
        states[model.id] ?? .notDownloaded
    }

    /// Whether any of the model's files are on this Mac: a download, whole or not, or the copy an
    /// earlier version made.
    public func canRemove(_ model: SpeechModelCatalog.Model) -> Bool {
        removable.contains(model.id) && tasks[model.id] == nil
    }

    /// Looks at the disk again, for models downloaded or removed since: by loading one, or by
    /// another program that shares the Hugging Face cache.
    public func refresh() {
        for model in catalog.models where tasks[model.id] == nil {
            let isDownloaded = downloads.folder(for: model) != nil
            if isDownloaded || !(states[model.id].map(Self.isFailure) ?? false) {
                states[model.id] = isDownloaded ? .downloaded : .notDownloaded
            }
            if downloads.hasFiles(of: model) {
                removable.insert(model.id)
            } else {
                removable.remove(model.id)
            }
        }
    }

    /// Downloads the model at its pinned commit, unless it's downloading already.
    public func download(_ model: SpeechModelCatalog.Model) {
        guard tasks[model.id] == nil else { return }
        states[model.id] = .downloading(fraction: 0)
        let downloads = self.downloads
        tasks[model.id] = Task {
            let outcome: State
            do {
                _ = try await downloads.download(model) { fraction in
                    self.downloadProgressed(model.id, fraction: fraction)
                }
                outcome = .downloaded
            } catch {
                if Task.isCancelled || error is CancellationError {
                    Log.transcription.info("Download of \(model.mac.repository.rawValue, privacy: .public) cancelled")
                    outcome = .notDownloaded
                } else {
                    Log.transcription.error(
                        "Download of \(model.mac.repository.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
                    )
                    outcome = .failed(error.localizedDescription)
                }
            }
            tasks[model.id] = nil
            states[model.id] = outcome
            refreshRemovable(model)
        }
    }

    public func cancelDownload(_ model: SpeechModelCatalog.Model) {
        tasks[model.id]?.cancel()
    }

    /// Removes every copy of the model. Settings keeps the model in use from being removed.
    public func remove(_ model: SpeechModelCatalog.Model) {
        guard tasks[model.id] == nil else { return }
        do {
            try downloads.remove(model)
            removalError = nil
        } catch {
            Log.transcription.error("Couldn't remove \(model.mac.repository.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
            removalError = "\(model.name) couldn't be removed: \(error.localizedDescription)"
        }
        states[model.id] = downloads.folder(for: model) == nil ? .notDownloaded : .downloaded
        refreshRemovable(model)
    }

    private func downloadProgressed(_ id: SpeechModelCatalog.Model.ID, fraction: Double) {
        guard tasks[id] != nil else { return }
        states[id] = .downloading(fraction: fraction)
    }

    private func refreshRemovable(_ model: SpeechModelCatalog.Model) {
        if downloads.hasFiles(of: model) {
            removable.insert(model.id)
        } else {
            removable.remove(model.id)
        }
    }

    private static func isFailure(_ state: State) -> Bool {
        if case .failed = state { true } else { false }
    }
}
