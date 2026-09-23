import Foundation

/// A word or name the user wants spelled their way, with the ways speech-to-text mishears it.
///
/// Speech-to-text spells unfamiliar names phonetically ("nerd storm" for "Nerdstorm"). Each
/// entry teaches the pipeline the canonical spelling twice over: the spoken variants are
/// replaced deterministically before cleanup, and the term is listed in the cleanup prompt so
/// the language model can fix mishearings nobody listed.
public struct VocabularyEntry: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    /// The canonical spelling, for example "Nerdstorm", "GitHub" or "Siobhan".
    public var term: String
    /// What speech-to-text writes instead, for example "nerd storm" or "nerd store". Matched as
    /// whole words, ignoring case and the punctuation around them.
    public var spokenVariants: [String]

    public init(id: UUID = UUID(), term: String, spokenVariants: [String] = []) {
        self.id = id
        self.term = term
        self.spokenVariants = spokenVariants
    }

    private enum CodingKeys: String, CodingKey {
        case id, term, spokenVariants
    }

    /// A missing `spokenVariants` reads as none. A term typed into the file by hand often has
    /// no variants, and one such entry must not get the whole file set aside as corrupt. The
    /// `id` stays required: a new one on every read would stop ``VocabularyStore/delete(id:)``
    /// and ``VocabularyStore/upsert(_:)`` from ever finding the entry.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.term = try container.decode(String.self, forKey: .term)
        self.spokenVariants = try container.decodeIfPresent([String].self, forKey: .spokenVariants) ?? []
    }

    /// The entry as it is stored: whitespace trimmed and collapsed, and variants that are empty,
    /// repeated, or only the term in different casing or punctuation removed.
    ///
    /// A variant equal to the term would make the replacer re-case the term everywhere, which for
    /// a plain word ("Go", "Swift") corrupts ordinary speech; the replacer re-cases only terms
    /// with distinctive casing on its own. Variants are compared as the replacer sees them, so
    /// "Nerd storm." and "nerd storm" count as one, and "go!" is the term "Go" again.
    public func sanitized() -> VocabularyEntry {
        let term = Self.collapsingWhitespace(term)
        var seen: Set<String> = [WordTokenizer.phraseKey(term)]
        var variants: [String] = []
        for variant in spokenVariants.map(Self.collapsingWhitespace) {
            let key = WordTokenizer.phraseKey(variant)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            variants.append(variant)
        }
        return VocabularyEntry(id: id, term: term, spokenVariants: variants)
    }

    private static func collapsingWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// Checks a whole vocabulary before it is saved.
///
/// The replacer needs every spoken phrase to point at exactly one term; with two candidates it
/// would pick one silently and the user would never learn why the other never appears.
public enum VocabularyValidator {
    /// `entries` sanitised (see ``VocabularyEntry/sanitized()``), or the first problem found, in
    /// entry order.
    ///
    /// - Throws: ``VocabularyError/emptyTerm`` for an entry without a word,
    ///   ``VocabularyError/duplicateTerm(_:)`` for a term already listed in any casing, and
    ///   ``VocabularyError/conflictingVariant(variant:firstTerm:secondTerm:)`` for a spoken
    ///   variant that another entry also claims, as a variant or as its term.
    ///
    /// Two terms are compared by their exact spelling, ignoring case only, and never by the words
    /// the matcher sees: "C++" and "C#" both reduce to the word "c", yet they are different
    /// terms and a developer's vocabulary needs both. A variant is compared the way the matcher
    /// sees it, so "go" on "Golang" conflicts with the term "Go": the user meant one of them.
    public static func validated(_ entries: [VocabularyEntry]) throws -> [VocabularyEntry] {
        let sanitized = entries.map { $0.sanitized() }
        var termsByLowercase: Set<String> = []
        var termClaims: [String: String] = [:]
        var variantClaims: [String: String] = [:]
        for entry in sanitized {
            let termKey = WordTokenizer.phraseKey(entry.term)
            guard !termKey.isEmpty else { throw VocabularyError.emptyTerm }
            guard termsByLowercase.insert(entry.term.lowercased()).inserted else {
                throw VocabularyError.duplicateTerm(entry.term)
            }
            if let owner = variantClaims[termKey] {
                throw VocabularyError.conflictingVariant(variant: entry.term, firstTerm: owner, secondTerm: entry.term)
            }
            // Sanitising leaves the variants of one entry distinct from each other and from its
            // term, so any claim found here belongs to an earlier entry.
            for variant in entry.spokenVariants {
                let key = WordTokenizer.phraseKey(variant)
                if let owner = variantClaims[key] ?? termClaims[key] {
                    throw VocabularyError.conflictingVariant(variant: variant, firstTerm: owner, secondTerm: entry.term)
                }
                variantClaims[key] = entry.term
            }
            if termClaims[termKey] == nil {
                termClaims[termKey] = entry.term
            }
        }
        return sanitized
    }
}
