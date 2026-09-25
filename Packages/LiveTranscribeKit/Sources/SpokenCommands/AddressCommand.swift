import Foundation
import Shared

/// Email and web addresses said aloud, however speech-to-text wrote the dots: "john dot smith
/// at example dot com" or "john.smith at example.com" → "john.smith@example.com", "example dot
/// com slash pricing" → "example.com/pricing", "w w w dot example dot org" → "www.example.org".
///
/// A domain must end in a known top-level domain ("com", "org", "io", …), so "dot" in ordinary
/// speech stays a word. "at" makes an email only when the name before it looks like one: it has
/// a dot, underscore, hyphen or digit ("john.smith"), or follows a word such as "email", "to" or
/// "is" ("email support at example.com"); "look at example.com" and "contact us at example.com"
/// keep their "at". A domain speech-to-text already wrote as one word is left as it is unless it
/// gains a name before it or a path after it; an email address it already wrote
/// ("John.Smith@example.com") is taken whole.
///
/// The address goes behind a placeholder, lowercased except for its path, so the model cannot
/// capitalise or split it.
public struct AddressCommand: PhraseMatcher {
    /// Common top-level domains, generic and country codes.
    public static let commonTopLevelDomains: Set<String> = [
        "com", "org", "net", "edu", "gov", "mil", "int", "io", "ai", "co", "dev", "app", "me", "info", "biz",
        "xyz", "tech", "online", "site", "store", "shop", "cloud", "blog", "news", "design", "page", "ly", "tv",
        "fm", "gg", "so", "sh", "to", "us", "uk", "ca", "au", "nz", "in", "lk", "de", "fr", "es", "it", "nl",
        "se", "no", "dk", "fi", "ie", "ch", "at", "be", "pl", "pt", "jp", "cn", "kr", "sg", "hk", "my", "id",
        "ph", "th", "vn", "br", "mx", "ar", "cl", "za", "ng", "ke", "ae", "sa", "il", "tr", "ru", "ua", "eu",
        "asia", "email", "live", "art", "studio", "agency", "team", "works", "world", "life", "today", "space",
        "website", "tools", "software", "systems", "solutions", "digital", "network", "media", "social", "inc",
    ]

    /// Words that make a plain name before "at" an email name: "email john at …", "it's to
    /// support at …".
    static let emailCues: Set<String> = [
        "email", "e-mail", "emails", "emailing", "emailed", "mail", "mailing", "is", "was", "to", "at",
        "contact", "reach", "cc", "bcc", "from", "address",
    ]
    /// Plain names that are never email names: "contact us at example.com".
    static let pronouns: Set<String> = [
        "me", "us", "you", "him", "her", "them", "it", "we", "i", "they", "she", "he", "one", "everyone", "someone", "anyone",
    ]
    /// A spoken domain never starts with these: "the dot com bubble" is not the.com.
    static let notDomainStarts: Set<String> = [
        "the", "a", "an", "and", "or", "but", "of", "in", "on", "at", "to", "for", "with", "is", "was", "are",
        "were", "be", "this", "that", "it", "its", "said", "says", "say",
    ]
    /// Spoken separators inside an email name.
    static let nameSeparators: [String: String] = ["dot": ".", "underscore": "_", "dash": "-", "hyphen": "-"]

    private let topLevelDomains: Set<String>

    public init(topLevelDomains: Set<String> = Self.commonTopLevelDomains) {
        self.topLevelDomains = topLevelDomains
    }

    public func matches(in text: TokenizedText) -> [PhraseMatch] {
        let tokens = (0..<text.tokens.count).map { AddressToken(text.token($0)) }
        let wordsOfToken = Self.wordRanges(in: text)
        var found: [PhraseMatch] = []
        var index = 0
        while index < tokens.count {
            if let email = writtenEmail(tokens[index]), let words = wordsOfToken[index] {
                found.append(PhraseMatch(
                    words: words,
                    replacement: .placeholder(trigger: email, expansion: email, role: .content),
                    keptLeading: String(tokens[index].leading),
                    keptTrailing: String(tokens[index].trailing)
                ))
                index += 1
                continue
            }
            guard let domain = domain(startingAt: index, in: tokens) else {
                index += 1
                continue
            }
            let address: String
            var start = index
            if let name = emailName(before: index, in: tokens) {
                start = name.start
                address = name.text + "@" + domain.host
            } else if domain.spoken || !domain.path.isEmpty {
                address = domain.host + domain.path
            } else {
                index = domain.end + 1
                continue
            }
            guard let first = wordsOfToken[start], let last = wordsOfToken[domain.end] else {
                index = domain.end + 1
                continue
            }
            found.append(PhraseMatch(
                words: first.lowerBound..<last.upperBound,
                replacement: .placeholder(trigger: address, expansion: address, role: .content),
                keptLeading: String(tokens[start].leading),
                keptTrailing: String(tokens[domain.end].trailing)
            ))
            index = domain.end + 1
        }
        return found
    }

    // MARK: - Domains

    private struct Domain {
        /// Lowercased labels joined with dots.
        let host: String
        /// "/pricing/2026", as spoken; empty without one.
        let path: String
        /// Index of the last token.
        let end: Int
        /// Said with "dot" or spelled "w w w", rather than written by speech-to-text.
        let spoken: Bool
    }

    private func domain(startingAt start: Int, in tokens: [AddressToken]) -> Domain? {
        var labels: [String] = []
        var path = ""
        var spoken = false
        var index = start
        while true {
            let token = tokens[index]
            if index > start, !token.leading.isEmpty { return nil }
            if token.core == "w", index + 2 < tokens.count,
               tokens[index + 1].core == "w", tokens[index + 2].core == "w",
               token.trailing.isEmpty, tokens[index + 1].isBare, tokens[index + 2].leading.isEmpty {
                labels.append("www")
                spoken = true
                index += 2
            } else {
                let parts = token.core.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
                let hostLabels = parts[0].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
                guard hostLabels.allSatisfy(Self.isLabel) else { return nil }
                labels += hostLabels
                if parts.count == 2 {
                    guard Self.isPath(String(parts[1])) else { return nil }
                    path = "/" + parts[1]
                    break
                }
            }
            guard index + 2 < tokens.count, tokens[index].trailing.isEmpty,
                  tokens[index + 1].core == "dot", tokens[index + 1].isBare,
                  tokens[index + 2].leading.isEmpty, Self.isLabel(tokens[index + 2].core)
            else { break }
            spoken = true
            index += 2
        }
        guard labels.count >= 2, let tld = labels.last, topLevelDomains.contains(tld) else { return nil }
        if spoken, Self.notDomainStarts.contains(labels[0]) { return nil }

        var end = index
        while tokens[end].trailing.isEmpty {
            var slash = end + 1
            if slash < tokens.count, tokens[slash].core == "forward", tokens[slash].isBare { slash += 1 }
            guard slash + 1 < tokens.count, tokens[slash].core == "slash", tokens[slash].isBare,
                  tokens[slash + 1].leading.isEmpty, Self.isPath(tokens[slash + 1].originalCore)
            else { break }
            path += "/" + tokens[slash + 1].originalCore
            end = slash + 1
        }
        return Domain(host: labels.joined(separator: "."), path: path, end: end, spoken: spoken)
    }

    // MARK: - Email names

    /// An email address speech-to-text already wrote as one word, lowercased: "John.Smith@example.com"
    /// → "john.smith@example.com". The model would otherwise capitalise the name in it.
    private func writtenEmail(_ token: AddressToken) -> String? {
        let parts = token.core.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, Self.isEmailName(String(parts[0])) else { return nil }
        let labels = parts[1].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard labels.count >= 2, labels.allSatisfy(Self.isLabel), let tld = labels.last, topLevelDomains.contains(tld) else {
            return nil
        }
        return token.core
    }

    /// The email name before "at" and the domain at `domainStart`, and the index of its first
    /// token.
    private func emailName(before domainStart: Int, in tokens: [AddressToken]) -> (start: Int, text: String)? {
        let at = domainStart - 1
        guard at >= 1, tokens[at].core == "at", tokens[at].isBare else { return nil }
        var index = at - 1
        guard tokens[index].trailing.isEmpty, Self.isEmailName(tokens[index].core) else { return nil }
        var parts = [tokens[index].core]
        while index >= 2, tokens[index].leading.isEmpty,
              let separator = Self.nameSeparators[tokens[index - 1].core], tokens[index - 1].isBare,
              tokens[index - 2].trailing.isEmpty, Self.isEmailName(tokens[index - 2].core) {
            parts.insert(contentsOf: [tokens[index - 2].core, separator], at: 0)
            index -= 2
        }
        let name = parts.joined()
        let looksLikeAnAddress = name.contains { ".-_+".contains($0) || $0.isNumber }
        if !looksLikeAnAddress {
            guard index >= 1, tokens[index - 1].trailing.isEmpty, Self.emailCues.contains(tokens[index - 1].core),
                  !Self.pronouns.contains(name)
            else { return nil }
        }
        return (index, name)
    }

    // MARK: - Characters

    private static func isLabel(_ label: String) -> Bool {
        guard let first = label.first, let last = label.last, first != "-", last != "-" else { return false }
        return label.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" }
    }

    private static func isEmailName(_ name: String) -> Bool {
        guard !name.isEmpty, name != "at", name != "dot" else { return false }
        return name.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || ".-_+%".contains($0) }
    }

    private static func isPath(_ segment: String) -> Bool {
        !segment.isEmpty && segment.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || "-._~/".contains($0) }
    }

    /// Each token's word indices; `nil` for a token without words.
    private static func wordRanges(in text: TokenizedText) -> [Range<Int>?] {
        var ranges = [Range<Int>?](repeating: nil, count: text.tokens.count)
        for (index, word) in text.words.enumerated() {
            let lower = ranges[word.token]?.lowerBound ?? index
            ranges[word.token] = lower..<(index + 1)
        }
        return ranges
    }
}

/// A token split into its punctuation and the characters between.
private struct AddressToken {
    let leading: Substring
    /// Between the leading and trailing punctuation, lowercased.
    let core: String
    /// The same characters as they were written, for a path.
    let originalCore: String
    let trailing: Substring

    init(_ token: Substring) {
        leading = TokenEdges.leading(of: token)
        trailing = TokenEdges.trailing(of: token)
        originalCore = String(token.dropFirst(leading.count).dropLast(trailing.count))
        core = originalCore.lowercased()
    }

    /// No punctuation on either side.
    var isBare: Bool { leading.isEmpty && trailing.isEmpty }
}
