/// The letters a language is written in, by its ISO 15924 code, as the catalog's language
/// choices name them (`"script": "Sinh"`): what a ``ScriptLock`` keeps a told Qwen3-ASR to.
public enum WritingScript: String, CaseIterable, Decodable, Hashable, Sendable {
    case latin = "Latn"
    case cyrillic = "Cyrl"
    case greek = "Grek"
    case arabic = "Arab"
    case devanagari = "Deva"
    case sinhala = "Sinh"
    case thai = "Thai"
    /// Chinese characters, for Chinese and Cantonese.
    case han = "Hani"
    /// Chinese characters, hiragana and katakana.
    case japanese = "Jpan"
    /// Hangul.
    case korean = "Kore"

    /// Its letters and its own punctuation, as Unicode blocks.
    var blocks: [ClosedRange<UInt32>] {
        switch self {
        case .latin:
            // Latin-1's letters, Extended-A and -B, the modifier letters (the ʻokina) and Extended
            // Additional (Vietnamese).
            [0x00C0...0x024F, 0x02B0...0x02FF, 0x1E00...0x1EFF]
        case .cyrillic:
            [0x0400...0x052F]
        case .greek:
            [0x0370...0x03FF, 0x1F00...0x1FFF]
        case .arabic:
            [0x0600...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF, 0xFB50...0xFDFF, 0xFE70...0xFEFF]
        case .devanagari:
            [0x0900...0x097F, 0xA8E0...0xA8FF]
        case .sinhala:
            [0x0D80...0x0DFF]
        case .thai:
            [0x0E00...0x0E7F]
        case .han:
            Self.cjkPunctuation + Self.hanCharacters
        case .japanese:
            Self.cjkPunctuation + Self.hanCharacters + [0x3040...0x30FF, 0x31F0...0x31FF]
        case .korean:
            Self.cjkPunctuation + [0x1100...0x11FF, 0x3130...0x318F, 0xAC00...0xD7AF]
        }
    }

    /// CJK symbols and punctuation (。、「」), and the full-width forms (，！？).
    private static let cjkPunctuation: [ClosedRange<UInt32>] = [0x3000...0x303F, 0xFF00...0xFFEF]
    /// The radicals, the unified ideographs and their extensions, and the compatibility ideographs.
    private static let hanCharacters: [ClosedRange<UInt32>] = [
        0x2E80...0x2FDF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F,
    ]
}
