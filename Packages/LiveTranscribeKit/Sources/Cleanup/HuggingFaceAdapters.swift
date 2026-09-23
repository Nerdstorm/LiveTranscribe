import Foundation
import HuggingFace
import MLXLMCommon
import Shared
import Tokenizers

// mlx-swift-lm 3.x takes its downloader and tokenizer through protocols. These adapters are the
// hand-written equivalent of its MLXHuggingFace macros, which would need Xcode's per-package
// macro-trust prompt to build.
//
// Portions adapted from mlx-swift-lm (https://github.com/ml-explore/mlx-swift-lm),
// Copyright (c) 2024 ml-explore, MIT License.

/// Downloads model snapshots with `HuggingFace.HubClient`.
struct HubDownloader: MLXLMCommon.Downloader {
    private let client: HubClient

    init(client: HubClient = HubClient()) {
        self.client = client
    }

    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        guard let repoID = Repo.ID(rawValue: id) else {
            throw CleanupModelError.invalidModelID(id)
        }
        let requested = resolvedRevision(revision ?? "main", of: repoID, useLatest: useLatest)
        let snapshot = try await client.downloadSnapshot(
            of: repoID,
            revision: requested,
            matching: patterns,
            progressHandler: { @MainActor progress in
                progressHandler(progress)
            }
        )
        if let commit = commitToRecord(after: requested, of: repoID) {
            await recordFileList(of: repoID, at: commit, matching: patterns)
        }
        return snapshot
    }

    /// Swaps a branch name for the commit it pointed to at the last download, unless the caller
    /// wants the latest revision.
    ///
    /// swift-huggingface serves a complete cached snapshot of a commit without touching the
    /// network, but always asks the Hub what a branch points to. Resolving the branch locally,
    /// together with ``commitToRecord(after:of:)``, keeps every launch after the first one
    /// offline. A missing or incomplete snapshot still downloads, at that same commit.
    func resolvedRevision(_ revision: String, of repo: Repo.ID, useLatest: Bool) -> String {
        guard !useLatest, let commit = client.cache?.resolveRevision(repo: repo, kind: .model, ref: revision) else {
            return revision
        }
        return commit
    }

    /// The commit whose file list still has to be recorded after downloading `revision`, or
    /// `nil` when the download recorded it already.
    ///
    /// swift-huggingface's offline path needs the snapshot's file list, and it saves that list
    /// only when the download asked for a commit. A branch download, as on first launch, leaves
    /// it unsaved, and the next launch would then list the files on the Hub again.
    func commitToRecord(after revision: String, of repo: Repo.ID) -> String? {
        guard !Self.isCommit(revision) else { return nil }
        return client.cache?.resolveRevision(repo: repo, kind: .model, ref: revision)
    }

    /// Lists the snapshot's files once more by commit, which makes swift-huggingface save the
    /// list. Every file is already cached at that commit, so nothing is downloaded again. On
    /// failure the next launch makes the same request instead.
    private func recordFileList(of repo: Repo.ID, at commit: String, matching patterns: [String]) async {
        do {
            _ = try await client.downloadSnapshot(of: repo, revision: commit, matching: patterns)
        } catch {
            Log.cleanup.notice(
                "Could not record the file list of \(repo.description, privacy: .public) at \(commit, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Hub commits are 40 hex digits; anything else is a branch or tag.
    static func isCommit(_ revision: String) -> Bool {
        revision.count == 40 && revision.allSatisfy(\.isHexDigit)
    }
}

/// Loads tokenizers from a local model folder with swift-transformers.
struct TransformersTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let upstream = try await AutoTokenizer.from(modelFolder: directory)
        return TokenizerBridge(upstream)
    }
}

/// Presents a swift-transformers tokenizer as an mlx-swift-lm tokenizer.
private struct TokenizerBridge: MLXLMCommon.Tokenizer {
    private let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) {
        self.upstream = upstream
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        upstream.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        upstream.convertIdToToken(id)
    }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}

public enum CleanupModelError: LocalizedError, Equatable {
    case invalidModelID(String)

    public var errorDescription: String? {
        switch self {
        case .invalidModelID(let id): "Invalid cleanup model id: \(id)"
        }
    }
}
