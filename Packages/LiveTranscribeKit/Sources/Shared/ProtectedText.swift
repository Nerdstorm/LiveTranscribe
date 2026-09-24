import Foundation

/// One phrase occurrence hidden behind an opaque token such as `⟦S1⟧` while the language model
/// runs: a snippet's trigger, a spoken emoji or line break, a list item number.
///
/// The token format is ``PlaceholderToken``'s, shared with Cleanup's output guard. Its brackets
/// are mathematical white square brackets (U+27E6, U+27E7): speech-to-text never produces them,
/// and a language model has no reason to "correct" them.
public struct Placeholder: Sendable, Equatable {
    /// What a token stands for, which decides when it is put back.
    public enum Role: Sendable, Equatable, CaseIterable {
        /// Text that must arrive verbatim: a snippet's expansion, an emoji, an address. Put back
        /// last, so layout never changes it (a list item starting with a URL keeps its case).
        case content
        /// A line or paragraph break the speaker asked for. Put back before layout, which works
        /// on lines.
        case lineBreak
        /// A structure marker the layout rules lay out, such as a spoken list item number. Put
        /// back before layout; text that is not laid out gets the spoken words back instead.
        case structure
    }

    /// Opens every token.
    public static let opening = PlaceholderToken.opening
    /// Closes every token.
    public static let closing = PlaceholderToken.closing

    /// The token that stands in for the phrase, `⟦S<n>⟧`, numbered per occurrence from 1.
    public let token: String
    /// The phrase as it was defined: a snippet's trigger, or a spoken command's words.
    public let trigger: String
    /// The matched words exactly as the transcript had them, less the punctuation kept next to
    /// the token.
    public let spoken: String
    /// What the token becomes once the language model is done.
    public let expansion: String
    public let role: Role

    public init(token: String, trigger: String, spoken: String, expansion: String, role: Role) {
        self.token = token
        self.trigger = trigger
        self.spoken = spoken
        self.expansion = expansion
        self.role = role
    }
}

/// A transcript with its spoken phrases replaced by placeholder tokens, and what each token
/// stands for.
///
/// Built by ``PhraseProtector/protect(_:)``. The dictation flow sends ``text`` to the language
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

    /// The transcript with each phrase replaced by its token or its text; identical to the input
    /// when no phrase was found.
    public let text: String
    /// One entry per protected phrase occurrence, in order of appearance.
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

    /// Whether any token stands for a line break or a structure marker, which need tidying and
    /// layout once they are put back.
    public var hasLayoutPlaceholders: Bool {
        placeholders.contains { $0.role != .content }
    }

    /// ``text`` with every token replaced by its expansion: the transcript as it would read had
    /// the language model not been used.
    public var expanded: String {
        expanded { $0.expansion }
    }

    /// ``text`` with every token replaced by `replacement(placeholder)`.
    public func expanded(_ replacement: (Placeholder) -> String) -> String {
        segments.map { segment in
            switch segment {
            case .literal(let literal): literal
            case .placeholder(let index): replacement(placeholders[index])
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
        restore(in: output) { $0.expansion }
    }

    /// `output` with each token of `roles` replaced by its expansion and every other token left
    /// in place, or `nil` if the tokens did not survive intact.
    public func restore(in output: String, roles: Set<Placeholder.Role>) -> String? {
        restore(in: output) { roles.contains($0.role) ? $0.expansion : nil }
    }

    /// `output` with each token replaced by the text `replacement` returns for it, or left in
    /// place when it returns `nil`; `nil` if the tokens did not survive intact.
    ///
    /// Restoring in steps lets layout work on text whose line breaks are in place while snippets
    /// and emoji are still tokens it cannot change. A token that is replaced must appear exactly
    /// once. One left in place may appear at most once, since a later call replaces it and checks
    /// it then. Anything else in token brackets fails, as in ``restore(in:)``.
    public func restore(in output: String, resolving replacement: (Placeholder) -> String?) -> String? {
        switch substitute(in: output, replacement: replacement) {
        case .success(let restored):
            return restored
        case .failure(let problem):
            Log.dictation.notice("Placeholders not intact in the cleaned text: \(problem.description, privacy: .public)")
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

    private func substitute(
        in output: String,
        replacement: (Placeholder) -> String?
    ) -> Result<String, PlaceholderProblem> {
        let issued = Dictionary(uniqueKeysWithValues: placeholders.map { ($0.token, $0) })
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
            guard let placeholder = issued[candidate] else { return .failure(.unknownToken) }
            occurrences[candidate, default: 0] += 1
            if let text = replacement(placeholder) {
                restored += output[copiedUpTo..<index]
                restored += text
                copiedUpTo = output.index(after: close)
            }
            index = output.index(after: close)
        }
        restored += output[copiedUpTo...]

        let missing = placeholders.filter { occurrences[$0.token] == nil && replacement($0) != nil }.count
        guard missing == 0 else { return .failure(.missing(missing)) }
        let repeated = occurrences.values.filter { $0 > 1 }.count
        guard repeated == 0 else { return .failure(.repeated(repeated)) }
        return .success(restored)
    }
}
