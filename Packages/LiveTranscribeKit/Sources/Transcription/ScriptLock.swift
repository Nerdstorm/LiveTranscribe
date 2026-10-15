/// What Qwen3-ASR may write once it's told a language: the language's letters (its
/// ``WritingScript``), Latin letters for words in English (as the Sinhala fine-tune writes them),
/// and the digits, punctuation and spaces every language shares.
///
/// Telling Qwen3-ASR a language only stands in for its own guess at it, so a language spoken
/// clearly still came out in its own letters (LiveTranscribe-0415). Locked, a model told English
/// can't write Sinhala or Chinese, whatever it hears. It can still write German, which has the
/// same letters.
///
/// The model writes UTF-8 a token at a time, and a token can hold part of a character, so the
/// lock reads a token's bytes after whatever character the tokens before it left unfinished
/// (``PartialCharacter``).
struct ScriptLock: Hashable, Sendable {
    /// What every language may write: ASCII; Latin-1's symbols and punctuation (« » ¿ ° × ÷); the
    /// combining diacritics; general punctuation (– — “ ” …, and the zero-width joiners Sinhala's
    /// conjuncts are written with); currency; letterlike symbols and number forms (℃ ½).
    static let shared: [ClosedRange<UInt32>] = [
        0x0000...0x007F, 0x00A0...0x00BF, 0x00D7...0x00D7, 0x00F7...0x00F7, 0x0300...0x036F,
        0x2000...0x206F, 0x20A0...0x20CF, 0x2100...0x218F,
    ]

    let script: WritingScript
    /// The code points it allows, in order and apart.
    private let allowed: [ClosedRange<UInt32>]

    init(script: WritingScript) {
        self.script = script
        let english = script == .latin ? [] : WritingScript.latin.blocks
        allowed = Self.merged(Self.shared + english + script.blocks)
    }

    func allows(_ scalar: UInt32) -> Bool {
        allowsAny(from: scalar, through: scalar)
    }

    /// Whether it allows any code point from `low` through `high`.
    func allowsAny(from low: UInt32, through high: UInt32) -> Bool {
        allowed.contains { $0.lowerBound <= high && low <= $0.upperBound }
    }

    /// The character left unfinished once `bytes` follow `partial`, the one the tokens before
    /// them left unfinished: ``PartialCharacter/nothing`` if they end on a whole character.
    /// `nil` if they write a character the lock doesn't allow, begin one no allowed character
    /// begins with, or aren't UTF-8.
    func partial(after partial: PartialCharacter, reading bytes: some Sequence<UInt8>) -> PartialCharacter? {
        var partial = partial
        for byte in bytes {
            guard let next = partial.appending(byte) else { return nil }
            if next.isWhole {
                guard allows(next.value) else { return nil }
                partial = .nothing
            } else {
                guard allowsAny(from: next.lowest, through: next.highest) else { return nil }
                partial = next
            }
        }
        return partial
    }

    private static func merged(_ ranges: [ClosedRange<UInt32>]) -> [ClosedRange<UInt32>] {
        var merged: [ClosedRange<UInt32>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, range.lowerBound <= last.upperBound + 1 {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}

/// A character whose first UTF-8 bytes are written and whose last aren't yet.
struct PartialCharacter: Hashable, Sendable {
    /// No character is unfinished.
    static let nothing = PartialCharacter(length: 0, count: 0, value: 0)

    /// How many bytes the character takes, which its first byte says.
    private let length: Int
    /// How many of them are written.
    private let count: Int
    /// The bits of the code point the written bytes hold.
    fileprivate let value: UInt32

    /// Its bytes are all written, or none is unfinished.
    var isWhole: Bool { count == length }

    /// The lowest and highest code points the character can still turn out to be. The lowest
    /// leaves out the overlong encodings, which write a code point in more bytes than it takes.
    fileprivate var lowest: UInt32 { max(value << (6 * UInt32(length - count)), [0, 0, 0x80, 0x800, 0x10000][length]) }
    fileprivate var highest: UInt32 { value << (6 * UInt32(length - count)) | ((1 << (6 * UInt32(length - count))) - 1) }

    /// The character with `byte` written next, or the one `byte` begins once this one is whole;
    /// `nil` if UTF-8 can't have `byte` next.
    fileprivate func appending(_ byte: UInt8) -> PartialCharacter? {
        guard isWhole else {
            guard byte & 0xC0 == 0x80 else { return nil }
            return PartialCharacter(length: length, count: count + 1, value: value << 6 | UInt32(byte & 0x3F))
        }
        switch byte {
        case 0x00...0x7F: return PartialCharacter(length: 1, count: 1, value: UInt32(byte))
        case 0xC2...0xDF: return PartialCharacter(length: 2, count: 1, value: UInt32(byte & 0x1F))
        case 0xE0...0xEF: return PartialCharacter(length: 3, count: 1, value: UInt32(byte & 0x0F))
        case 0xF0...0xF4: return PartialCharacter(length: 4, count: 1, value: UInt32(byte & 0x07))
        default: return nil
        }
    }
}
