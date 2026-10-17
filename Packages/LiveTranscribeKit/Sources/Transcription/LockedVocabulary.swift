import Foundation

/// Qwen3-ASR's vocabulary as the bytes each token writes, from the model's `vocab.json`, to find
/// the tokens a ``ScriptLock`` lets the model write next.
///
/// The vocabulary holds the byte-level BPE tokens only. Qwen's added tokens (`<|im_end|>`,
/// `<asr_text>`, ...) come after them, and the model's logits after those, padded; none of them
/// writes text, so the lock allows none but the ends of a reply.
final class LockedVocabulary {
    enum LoadError: Error, Equatable {
        case unreadable(String)
        /// A token id is missing, so the ids don't run from 0 without a gap.
        case missingToken(Int)
    }

    /// Each token's bytes, one token after another: token `i`'s run from `starts[i]` up to
    /// `starts[i + 1]`.
    private let bytes: [UInt8]
    private let starts: [Int]
    /// The tokens that end the reply, which may follow a whole character only.
    private let endOfReply: Set<Int>

    /// How many tokens the vocabulary holds.
    var count: Int { starts.count - 1 }

    /// Reads `vocab.json`, which spells each token's bytes in GPT-2's byte-level alphabet.
    init(vocabularyJSON data: Data, endOfReply: Set<Int>) throws(LoadError) {
        let ids: [String: Int]
        do {
            ids = try JSONDecoder().decode([String: Int].self, from: data)
        } catch {
            throw .unreadable(String(describing: error))
        }
        var tokens = [String?](repeating: nil, count: ids.count)
        for (token, id) in ids where tokens.indices.contains(id) {
            tokens[id] = token
        }
        var bytes: [UInt8] = []
        var starts = [0]
        for (id, token) in tokens.enumerated() {
            guard let token else { throw .missingToken(id) }
            // A character outside the alphabet, which no byte-level vocabulary has, writes nothing,
            // and the lock never allows writing nothing but the end.
            if let written = Self.bytes(spelt: token) {
                bytes += written
            }
            starts.append(bytes.count)
        }
        self.bytes = bytes
        self.starts = starts
        self.endOfReply = endOfReply
    }

    /// The bytes `token` writes; none past the vocabulary.
    func bytes(of token: Int) -> ArraySlice<UInt8> {
        guard token >= 0, token < count else { return [] }
        return bytes[starts[token]..<starts[token + 1]]
    }

    /// Which of `logitCount` tokens `lock` lets the model write after `partial`: the vocabulary's
    /// that write only what the lock allows, and an end of the reply after a whole character.
    func allowed(by lock: ScriptLock, after partial: PartialCharacter, logitCount: Int) -> [Bool] {
        var allowed = [Bool](repeating: false, count: logitCount)
        for token in 0..<min(count, logitCount) where starts[token] < starts[token + 1] {
            allowed[token] = lock.partial(after: partial, reading: bytes(of: token)) != nil
        }
        if partial.isWhole {
            for token in endOfReply where token < logitCount {
                allowed[token] = true
            }
        }
        return allowed
    }

    /// The bytes a token spells in GPT-2's byte-level alphabet; `nil` if it has a character the
    /// alphabet lacks.
    static func bytes(spelt token: String) -> [UInt8]? {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(token.unicodeScalars.count)
        for scalar in token.unicodeScalars {
            guard let byte = byteOf[scalar] else { return nil }
            bytes.append(byte)
        }
        return bytes
    }

    /// GPT-2's byte-level alphabet, as Qwen's vocabulary spells bytes: the printable Latin-1
    /// bytes stand for themselves, and the other 68 for the characters from U+0100 on, in byte
    /// order.
    private static let byteOf: [Unicode.Scalar: UInt8] = {
        var byteOf: [Unicode.Scalar: UInt8] = [:]
        var next: UInt32 = 0x100
        for byte in UInt8.min...UInt8.max {
            let printable = (0x21...0x7E).contains(byte) || (0xA1...0xAC).contains(byte) || (0xAE...0xFF).contains(byte)
            let scalar: UInt32
            if printable {
                scalar = UInt32(byte)
            } else {
                scalar = next
                next += 1
            }
            byteOf[Unicode.Scalar(scalar)!] = byte
        }
        return byteOf
    }()
}
