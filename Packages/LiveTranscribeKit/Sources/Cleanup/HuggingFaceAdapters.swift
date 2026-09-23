import Foundation
import HuggingFace
import MLXLMCommon
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
        return try await client.downloadSnapshot(
            of: repoID,
            revision: resolvedRevision(revision ?? "main", of: repoID, useLatest: useLatest),
            matching: patterns,
            progressHandler: { @MainActor progress in
                progressHandler(progress)
            }
        )
    }

    /// Swaps a branch name for the commit it pointed to at the last download, unless the caller
    /// wants the latest revision.
    ///
    /// swift-huggingface serves a complete cached snapshot of a commit without touching the
    /// network, but always asks the Hub what a branch points to. Resolving the branch locally
    /// keeps every launch after the first one offline. A missing or incomplete snapshot still
    /// downloads, at that same commit.
    func resolvedRevision(_ revision: String, of repo: Repo.ID, useLatest: Bool) -> String {
        guard !useLatest, let commit = client.cache?.resolveRevision(repo: repo, kind: .model, ref: revision) else {
            return revision
        }
        return commit
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
