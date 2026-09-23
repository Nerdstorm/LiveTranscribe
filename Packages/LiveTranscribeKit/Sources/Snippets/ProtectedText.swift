import Foundation
import Shared

/// One snippet occurrence hidden behind an opaque token such as `⟦S1⟧`.
///
/// The token format is ``PlaceholderToken``'s, shared with Cleanup's output guard. Its brackets
/// are mathematical white square brackets (U+27E6, U+27E7): speech-to-text never produces them,
/// and a language model has no reason to "correct" them.
public struct Placeholder: Sendable, Equatable {
    /// Opens every token.
    public static let opening = PlaceholderToken.opening
    /// Closes every token.
    public static let closing = PlaceholderToken.closing

    /// The token that stands in for the trigger, `⟦S<n>⟧`, numbered per occurrence from 1.
    public let token: String
    /// The snippet's trigger as the user defined it.
    public let trigger: String
    /// What the token becomes once the language model is done.
    public let expansion: String

    static func token(number: Int) -> String {
        PlaceholderToken.make(index: number)
    }
}

/// A transcript with its snippet triggers replaced by placeholder tokens, and what each token
/// stands for.
///
/// Built by ``SnippetExpander/protect(_:)``. The dictation flow sends ``text`` to the language
/// model, then calls ``restore(in:)`` on the output; when that returns `nil` the output changed a
/// placeholder and the flow falls back to the text it had before the model.
public struct ProtectedText: Sendable, Equatable {
    /// The pieces the protected text is made of. ``expanded`` is built from these rather than by
    /// searching ``text``, so token-like text that was already in the transcript stays as it was.
    enum Segment: Sendable, Equatable {
        case literal(String)
        /// An index into ``placeholders``.
        case placeholder(Int)
    }

    /// The transcript with each trigger replaced by its token; identical to the input when no
    /// trigger was found.
    public let text: String
    /// One entry per trigger occurrence, in order of appearance.
    public let placeholders: [Placeholder]
    private let segments: [Segment]

    init(segments: [Segment], placeholders: [Placeholder]) {
        self.segments = segments
        self.placeholders = placeholders
        self.text = segments.map { segment in
            switch segment {
            case .literal(let literal): literal
            case .placeholder(let index): placeholders[index].token
            }
        }.joined()
    }

    init(unchanged text: String) {
        self.text = text
        self.placeholders = []
        self.segments = [.literal(text)]
    }

    /// The tokens the language model must keep verbatim, in order of appearance.
    public var tokens: [String] {
        placeholders.map(\.token)
    }

    /// ``text`` with every token replaced by its expansion: the transcript as it would read had
    /// the language model not been used.
    public var expanded: String {
        segments.map { segment in
            switch segment {
            case .literal(let literal): literal
            case .placeholder(let index): placeholders[index].expansion
            }
        }.joined()
    }

    /// `output` with each token replaced by its expansion, or `nil` if the tokens did not survive
    /// intact.
    ///
    /// Every token must appear exactly once, and no other `⟦` or `⟧` may appear: a missing,
    /// repeated or altered token (`⟦S 1⟧`, `⟦S01⟧`, a lost bracket) means the model rewrote
    /// something it was told to keep, and inserting a partial or doubled expansion would be worse
    /// than using the text from before the model. Tokens may move. Each expansion is inserted
    /// verbatim in one pass, so an expansion that itself looks like a token is never substituted
    /// again.
    public func restore(in output: String) -> String? {
        switch substitute(in: output) {
        case .success(let restored):
            return restored
        case .failure(let problem):
            Log.snippets.notice("Placeholders not intact in the cleaned text: \(problem.description, privacy: .public)")
            return nil
        }
    }

    // MARK: - Private

    private enum PlaceholderProblem: Error, CustomStringConvertible {
        case unpairedBracket
        case unknownToken
        case missing(Int)
        case repeated(Int)

        var description: String {
            switch self {
            case .unpairedBracket: "a placeholder bracket without its partner"
            case .unknownToken: "a placeholder that was not issued"
            case .missing(let count): "\(count) placeholders missing"
            case .repeated(let count): "\(count) placeholders repeated"
            }
        }
    }

    private func substitute(in output: String) -> Result<String, PlaceholderProblem> {
        let expansions = Dictionary(uniqueKeysWithValues: placeholders.map { ($0.token, $0.expansion) })
        var occurrences: [String: Int] = [:]
        var restored = ""
        var copiedUpTo = output.startIndex
        var index = output.startIndex

        while index < output.endIndex {
            let character = output[index]
            if character == Placeholder.closing { return .failure(.unpairedBracket) }
            guard character == Placeholder.opening else {
                index = output.index(after: index)
                continue
            }
            guard let close = output[index...].firstIndex(of: Placeholder.closing) else {
                return .failure(.unpairedBracket)
            }
            let candidate = String(output[index...close])
            guard let expansion = expansions[candidate] else { return .failure(.unknownToken) }
            occurrences[candidate, default: 0] += 1
            restored += output[copiedUpTo..<index]
            restored += expansion
            index = output.index(after: close)
            copiedUpTo = index
        }
        restored += output[copiedUpTo...]

        let missing = placeholders.count - occurrences.count
        guard missing == 0 else { return .failure(.missing(missing)) }
        let repeated = occurrences.values.filter { $0 > 1 }.count
        guard repeated == 0 else { return .failure(.repeated(repeated)) }
        return .success(restored)
    }
}
