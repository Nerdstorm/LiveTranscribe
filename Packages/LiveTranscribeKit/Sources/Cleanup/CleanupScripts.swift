/// Scripts the cleanup model can't write back, so text in them skips the model.
///
/// Qwen3-1.7B drops Sinhala's vowel signs when it copies Sinhala text: "ඒකෙ තියෙන magic වැඩ" comes
/// back as "ඒක තයන magic වඩ". The output guard reads each damaged word as a respelling of the one
/// that was said and accepts it. At Medium the model garbled 4 of 24 Sinhala dictations this way,
/// and the guard rejected the other 20 after about 250 ms of generation, so the model does no good
/// on Sinhala at any level. Only Sinhala has been measured; other scripts are untested.
public enum CleanupScripts {
    /// Sinhala, U+0D80–U+0DFF.
    static let sinhala: ClosedRange<UInt32> = 0x0D80 ... 0x0DFF

    /// Whether the cleanup model can be given `text`: false when it has a character in a script
    /// the model can't write back, even among English words.
    public static func modelCanRewrite(_ text: String) -> Bool {
        !text.unicodeScalars.contains { sinhala.contains($0.value) }
    }
}
