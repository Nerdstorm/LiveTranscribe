import Foundation

/// Qwen3's answer without its reasoning. With thinking on, the model reasons in a `<think>` block
/// and then answers; only the answer may reach the text field, and ``OutputGuard`` still rejects
/// any tag left in it.
enum ThinkingOutput: Equatable {
    /// The text after the reasoning, or the whole output when the model answered without any.
    case answer(String)
    /// The reasoning used up the token budget or was cut off before it ended, so there is no
    /// answer to use.
    case unfinished

    static let opening = "<think>"
    static let closing = "</think>"

    init(_ output: String) {
        if let end = output.range(of: Self.closing, options: .backwards) {
            self = .answer(String(output[end.upperBound...]))
        } else if output.contains(Self.opening) {
            self = .unfinished
        } else {
            self = .answer(output)
        }
    }
}
