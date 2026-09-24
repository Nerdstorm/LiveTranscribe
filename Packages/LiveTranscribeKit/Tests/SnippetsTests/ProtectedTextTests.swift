import Foundation
import Shared
import Snippets
import Testing

@Suite("ProtectedText")
struct ProtectedTextTests {
    private let expander = SnippetExpander(snippets: [
        Snippet(trigger: "my calendar link", expansion: "https://cal.example.com/alex?week=1&view=agenda"),
        Snippet(trigger: "sign off", expansion: "Best wishes,\nAlex \u{1F44B}"),
    ])

    /// Two occurrences, so tokens `⟦S1⟧` and `⟦S2⟧`.
    private var twoPlaceholders: ProtectedText {
        expander.protect("here's my calendar link and sign off")
    }

    @Test func restoresTheUnchangedTextToTheExpandedText() throws {
        let protected = twoPlaceholders
        #expect(protected.text == "here's ⟦S1⟧ and ⟦S2⟧")
        #expect(try #require(protected.restore(in: protected.text)) == protected.expanded)
        #expect(protected.expanded == "here's https://cal.example.com/alex?week=1&view=agenda and Best wishes,\nAlex \u{1F44B}")
    }

    @Test func keepsTheModelsEditsAroundTheTokens() {
        let restored = twoPlaceholders.restore(in: "Here's ⟦S1⟧, and ⟦S2⟧.")
        #expect(restored == "Here's https://cal.example.com/alex?week=1&view=agenda, and Best wishes,\nAlex \u{1F44B}.")
    }

    @Test func allowsTheModelToMoveTokens() {
        #expect(twoPlaceholders.restore(in: "⟦S2⟧ ⟦S1⟧") == "Best wishes,\nAlex \u{1F44B} https://cal.example.com/alex?week=1&view=agenda")
    }

    @Test("Rejects output whose tokens did not survive intact", arguments: [
        "Here's the link and ⟦S2⟧.",
        "Here's ⟦S1⟧ and that's it.",
        "No tokens at all.",
        "⟦S1⟧ and ⟦S1⟧ and ⟦S2⟧",
        "⟦S1⟧ ⟦S2⟧ ⟦S2⟧",
        "⟦S 1⟧ and ⟦S2⟧",
        "[S1] and ⟦S2⟧",
        "⟦s1⟧ and ⟦S2⟧",
        "⟦S01⟧ and ⟦S2⟧",
        "S1 and ⟦S2⟧",
        "⟦S1 and ⟦S2⟧",
        "S1⟧ and ⟦S2⟧",
        "⟦S1⟧⟧ and ⟦S2⟧",
        "⟦⟦S1⟧ and ⟦S2⟧",
        "⟦S1⟧ and ⟦S2⟧ and ⟦S3⟧",
        "⟦S1⟧ and ⟦S2⟧ ⟦⟧",
        "⟦S1⟧\u{0301} and ⟦S2⟧",
        "\u{3010}S1\u{3011} and ⟦S2⟧",
        "⟦S1⟧ and ⟦S2⟧ ⟦S1",
    ])
    func rejectsDamagedTokens(output: String) {
        #expect(twoPlaceholders.restore(in: output) == nil)
    }

    @Test func textWithoutPlaceholdersRestoresToItselfUnlessATokenAppears() {
        let protected = expander.protect("Nothing to expand.")
        #expect(protected.restore(in: "Nothing to expand, really.") == "Nothing to expand, really.")
        #expect(protected.restore(in: "Nothing ⟦S1⟧ to expand.") == nil)
    }

    @Test func doesNotSubstituteTokenLikeTextInsideAnExpansion() throws {
        let expander = SnippetExpander(snippets: [
            Snippet(trigger: "template one", expansion: "see ⟦S2⟧ and [S1] here"),
            Snippet(trigger: "template two", expansion: "second ⟦S1⟧"),
        ])
        let protected = expander.protect("template one then template two")
        #expect(protected.text == "⟦S1⟧ then ⟦S2⟧")
        #expect(protected.expanded == "see ⟦S2⟧ and [S1] here then second ⟦S1⟧")
        #expect(try #require(protected.restore(in: "⟦S1⟧, then ⟦S2⟧.")) == "see ⟦S2⟧ and [S1] here, then second ⟦S1⟧.")
    }

    /// Speech-to-text never produces the brackets, but if a transcript already contained a
    /// token-like string, the fallback must not expand it and the model's output must not pass.
    @Test func tokenLikeTextAlreadyInTheTranscriptIsLeftAlone() {
        let expander = SnippetExpander(snippets: [Snippet(trigger: "sign off", expansion: "Bye")])
        let protected = expander.protect("keep ⟦S1⟧ literal, sign off")
        #expect(protected.text == "keep ⟦S1⟧ literal, ⟦S1⟧")
        #expect(protected.expanded == "keep ⟦S1⟧ literal, Bye")
        #expect(protected.restore(in: protected.text) == nil)
    }

    @Test func insertsExpansionsVerbatim() throws {
        let expansion = "Line one\n\n  indented: https://x.example/a_b?c=d#e \u{1F680} $1.50 \\n {\"k\": [1]}"
        let expander = SnippetExpander(snippets: [Snippet(trigger: "the block", expansion: expansion)])
        let protected = expander.protect("Insert the block.")
        #expect(try #require(protected.restore(in: "Insert ⟦S1⟧.")) == "Insert \(expansion).")
    }
}
