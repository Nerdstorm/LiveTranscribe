import Foundation
import Shared
import Testing
@testable import Vocabulary

/// The similarity search takes shortcuts for speed; these tests check it against the plain
/// ``EditDistance`` it must agree with, on many seeded random inputs.
@Suite("TermSimilarity")
struct TermSimilarityTests {
    @Test func boundedDistanceAgreesWithLevenshtein() {
        var random = SeededGenerator(seed: 1)
        // One set of rows for every call, as the search uses them: stale values must not leak.
        var rows = BoundedEditDistance.Rows()
        for _ in 0..<5000 {
            let source = (0..<Int.random(in: 0...9, using: &random)).map { _ in Int.random(in: 0...3, using: &random) }
            let target = (0..<Int.random(in: 0...9, using: &random)).map { _ in Int.random(in: 0...3, using: &random) }
            let limit = Int.random(in: -1...7, using: &random)
            let exact = EditDistance.levenshtein(source, target)
            let expected = limit >= 0 && exact <= limit ? exact : nil
            let actual = BoundedEditDistance.distance(source, target, limit: limit, rows: &rows)
            #expect(actual == expected, "\(source) → \(target), limit \(limit)")
        }
    }

    @Test("Finds the same terms, in the same order, as EditDistance", arguments: [0.0, 0.5, 0.7, 0.75, 0.8, 0.9, 1.0, 1.5, .nan])
    func agreesWithNormalizedSimilarity(threshold: Double) {
        var random = SeededGenerator(seed: 2)
        var found = 0
        for _ in 0..<60 {
            let phrasesByTerm = (0..<Int.random(in: 1...12, using: &random)).map { _ in
                (0..<Int.random(in: 1...3, using: &random)).map { _ in Self.phrase(using: &random) }
            }
            let text = (0..<Int.random(in: 0...12, using: &random)).map { _ in Self.word(using: &random) }
                .joined(separator: " ")
            let similarity = TermSimilarity(phrasesByTerm: phrasesByTerm, threshold: threshold)
            let excluded = Int.random(in: 0..<phrasesByTerm.count, using: &random)

            let actual = similarity.similarTerms(to: text, excluding: { $0 == excluded })

            let units = TermSimilarity.units(in: text)
            let expected = phrasesByTerm.enumerated()
                .filter { $0.offset != excluded }
                .compactMap { index, phrases -> (index: Int, score: Double)? in
                    let forms = phrases.filter { !EditDistance.normalize($0).isEmpty }
                    let scores = forms.flatMap { form in units.map { EditDistance.normalizedSimilarity(form, $0) } }
                    guard let best = scores.max(), best >= threshold else { return nil }
                    return (index, best)
                }
                .sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
                .map(\.index)
            #expect(actual == expected, "\(phrasesByTerm) in \"\(text)\"")
            found += expected.count
        }
        // Guards against a comparison that passes only because nothing is ever similar.
        if threshold <= 0.9 {
            #expect(found > 0)
        }
    }

    @Test func noTextOrNoTermsFindNothing() {
        #expect(TermSimilarity(phrasesByTerm: [["Kafka"]], threshold: 0.5).similarTerms(to: "", excluding: { _ in false }).isEmpty)
        #expect(TermSimilarity(phrasesByTerm: [], threshold: 0.5).similarTerms(to: "kafka", excluding: { _ in false }).isEmpty)
    }

    /// "é" written as one code point and as "e" plus a combining accent is the same character.
    @Test func canonicallyEquivalentCharactersMatch() {
        let similarity = TermSimilarity(phrasesByTerm: [["Caf\u{E9}"]], threshold: 1)
        #expect(similarity.similarTerms(to: "cafe\u{301}", excluding: { _ in false }) == [0])
    }

    /// Short words over a small alphabet, so near misses are common. The accented letters test
    /// grapheme handling and the capitals test normalisation.
    private static let letters: [String] = ["a", "b", "c", "e", "\u{E9}", "e\u{301}", "K", "-"]

    private static func word(using random: inout SeededGenerator) -> String {
        (0..<Int.random(in: 1...6, using: &random)).map { _ in letters.randomElement(using: &random) ?? "a" }.joined()
    }

    private static func phrase(using random: inout SeededGenerator) -> String {
        (0..<Int.random(in: 1...2, using: &random)).map { _ in word(using: &random) }.joined(separator: " ")
    }
}

/// SplitMix64: a small generator with a fixed seed, so every run tests the same inputs.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
