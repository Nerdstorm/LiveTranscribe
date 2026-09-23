import Shared
import Testing
import Vocabulary

@Suite("VocabularyReplacer")
struct VocabularyReplacerTests {
    private let replacer = VocabularyReplacer(entries: [
        VocabularyEntry(term: "Nerdstorm", spokenVariants: ["nerd storm", "nerd store"]),
        VocabularyEntry(term: "GitHub", spokenVariants: ["git hub"]),
        VocabularyEntry(term: "Qwen", spokenVariants: ["quen"]),
        VocabularyEntry(term: "Qwen3", spokenVariants: ["quen three", "qwen three"]),
        VocabularyEntry(term: "StormCloud", spokenVariants: ["storm cloud"]),
        VocabularyEntry(term: "Siobhan", spokenVariants: ["shivon"]),
    ])

    @Test("Replaces spoken variants with the canonical term", arguments: [
        ("I work at nerd storm.", "I work at Nerdstorm."),
        ("Nerd Storm is hiring", "Nerdstorm is hiring"),
        ("NERD STORE, again", "Nerdstorm, again"),
        ("shivon said so", "Siobhan said so"),
        ("push it to git hub", "push it to GitHub"),
        ("nerd storm and nerd store", "Nerdstorm and Nerdstorm"),
        ("the nerd  storm team", "the Nerdstorm team"),
        ("nerd-storm rocks", "Nerdstorm rocks"),
    ])
    func replacesVariants(input: String, expected: String) {
        #expect(replacer.apply(to: input) == expected)
    }

    @Test("Keeps punctuation around the match", arguments: [
        ("(nerd storm)", "(Nerdstorm)"),
        ("\u{201C}nerd storm\u{201D}?", "\u{201C}Nerdstorm\u{201D}?"),
        ("Hi, shivon! How are you?", "Hi, Siobhan! How are you?"),
        ("See: git hub...", "See: GitHub..."),
        ("git hub's API", "GitHub's API"),
        ("git hub\u{2019}s API", "GitHub\u{2019}s API"),
    ])
    func keepsPunctuation(input: String, expected: String) {
        #expect(replacer.apply(to: input) == expected)
    }

    @Test("Prefers the longest match at a position", arguments: [
        ("try quen three today", "try Qwen3 today"),
        ("try quen today", "try Qwen today"),
        ("try quen, three times", "try Qwen, three times"),
    ])
    func prefersLongestMatch(input: String, expected: String) {
        #expect(replacer.apply(to: input) == expected)
    }

    /// "nerd storm cloud" could be "Nerdstorm cloud" or "nerd StormCloud"; the leftmost wins.
    @Test func prefersTheLeftmostMatch() {
        #expect(replacer.apply(to: "a nerd storm cloud") == "a Nerdstorm cloud")
        #expect(replacer.apply(to: "a storm cloud") == "a StormCloud")
    }

    @Test("Matches whole words only", arguments: [
        "git hubs are fun",
        "the digit hub",
        "a nerd storming off",
        "supernerd storm",
        "quenched",
    ])
    func matchesWholeWordsOnly(input: String) {
        #expect(replacer.apply(to: input) == input)
    }

    /// A comma, full stop or line break between the words means they were not one name.
    @Test("Does not match across punctuation or lines", arguments: [
        "a nerd, storm of ideas",
        "I'm a nerd. Store it there.",
        "the nerd\nstorm",
        "git (hub)",
    ])
    func doesNotMatchAcrossBreaks(input: String) {
        #expect(replacer.apply(to: input) == input)
    }

    /// Grapheme clusters around and next to a match (emoji with modifiers, combining accents,
    /// CRLF) must neither shift the replaced range nor be split.
    @Test("Keeps multi-scalar characters around a match intact", arguments: [
        ("caf\u{E9} nerd storm \u{1F44D}\u{1F3FD}.", "caf\u{E9} Nerdstorm \u{1F44D}\u{1F3FD}."),
        ("cafe\u{301} nerd storm", "cafe\u{301} Nerdstorm"),
        ("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} git hub's", "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} GitHub's"),
        ("nerd storm\r\ngit hub", "Nerdstorm\r\nGitHub"),
        ("\u{00A0}nerd\u{00A0}storm\u{00A0}", "\u{00A0}Nerdstorm\u{00A0}"),
    ])
    func keepsMultiScalarCharacters(input: String, expected: String) {
        #expect(replacer.apply(to: input) == expected)
    }

    /// A combining mark on a word's last letter makes it a different word.
    @Test func aCombiningMarkMakesADifferentWord() {
        let input = "nerd store\u{301}"
        #expect(replacer.apply(to: input) == input)
    }

    @Test func textWithNothingToReplaceIsReturnedUnchanged() {
        let text = "Nothing  here, (really)... \u{2014} ok?\n"
        #expect(replacer.apply(to: text) == text)
        #expect(replacer.apply(to: "") == "")
        #expect(VocabularyReplacer(entries: []).apply(to: text) == text)
    }

    @Test func textAlreadyUsingTheTermIsUnchanged() {
        #expect(replacer.apply(to: "GitHub and Nerdstorm") == "GitHub and Nerdstorm")
    }

    @Test func multiWordTermsReplaceMultiWordVariants() {
        let replacer = VocabularyReplacer(entries: [
            VocabularyEntry(term: "Visual Studio Code", spokenVariants: ["v s code", "visual studios code"]),
        ])
        #expect(replacer.apply(to: "open v s code now") == "open Visual Studio Code now")
        #expect(replacer.apply(to: "open visual studios code.") == "open Visual Studio Code.")
    }

    @Test func theFirstEntryWinsWhenTwoClaimAPhrase() {
        let replacer = VocabularyReplacer(entries: [
            VocabularyEntry(term: "Kubernetes", spokenVariants: ["cube"]),
            VocabularyEntry(term: "Cube", spokenVariants: ["cube"]),
        ])
        #expect(replacer.apply(to: "a cube") == "a Kubernetes")
    }

    /// Snippet placeholders are substituted before vocabulary replacement; altering one would
    /// break the snippet's expansion.
    ///
    /// The tokens come from `PlaceholderToken`, the format Snippets writes, so a change to that
    /// format is tested here too.
    @Test("Never alters a snippet placeholder", arguments: [
        ("send \(PlaceholderToken.make(index: 1)) to nerd storm", "send \(PlaceholderToken.make(index: 1)) to Nerdstorm"),
        ("(\(PlaceholderToken.make(index: 1))) nerd storm", "(\(PlaceholderToken.make(index: 1))) Nerdstorm"),
        (
            PlaceholderToken.make(index: 1) + PlaceholderToken.make(index: 2),
            PlaceholderToken.make(index: 1) + PlaceholderToken.make(index: 2)
        ),
        ("nerd \(PlaceholderToken.make(index: 1)) storm", "nerd \(PlaceholderToken.make(index: 1)) storm"),
        ("nerd\(PlaceholderToken.make(index: 1))storm", "nerd\(PlaceholderToken.make(index: 1))storm"),
        ("an unclosed \(PlaceholderToken.opening)s1 stays text", "an unclosed \(PlaceholderToken.opening)Amazon S3 stays text"),
    ])
    func leavesPlaceholdersAlone(input: String, expected: String) {
        let replacer = VocabularyReplacer(entries: [
            VocabularyEntry(term: "Nerdstorm", spokenVariants: ["nerd storm"]),
            VocabularyEntry(term: "Amazon S3", spokenVariants: ["s1", "s2"]),
            VocabularyEntry(term: "s1"),
        ])
        #expect(replacer.apply(to: input) == expected)
    }

    /// Entries read from a hand-edited file have not been sanitised by the store.
    @Test func handEditedEntriesAreSanitizedBeforeUse() {
        let replacer = VocabularyReplacer(entries: [
            VocabularyEntry(term: "Go", spokenVariants: ["go", "GO!"]),
            VocabularyEntry(term: "  Nerdstorm\n", spokenVariants: ["  nerd   storm "]),
        ])
        #expect(replacer.apply(to: "let's go home") == "let's go home")
        #expect(replacer.apply(to: "at nerd storm.") == "at Nerdstorm.")
    }

    @Test func entriesWithoutATermAreIgnored() {
        let replacer = VocabularyReplacer(entries: [VocabularyEntry(term: "  ", spokenVariants: ["nothing"])])
        #expect(replacer.apply(to: "nothing to see") == "nothing to see")
    }
}

@Suite("VocabularyReplacer distinctive casing")
struct DistinctiveCasingTests {
    @Test("Re-cases terms with distinctive casing", arguments: [
        ("GitHub", "I use github daily", "I use GitHub daily"),
        ("GitHub", "GITHUB is down.", "GitHub is down."),
        ("iPhone", "my iphone broke", "my iPhone broke"),
        ("macOS", "on MacOS 15", "on macOS 15"),
        ("Qwen3", "qwen3 is small", "Qwen3 is small"),
        ("M4", "the m4 chip", "the M4 chip"),
        ("iPhone 16 Pro", "an iphone 16 pro case", "an iPhone 16 Pro case"),
        ("GitHub", "github's API", "GitHub's API"),
        ("4K", "a 4k screen", "a 4K screen"),
        ("O'Brien", "ask o'brien", "ask O'Brien"),
    ])
    func recasesDistinctiveTerms(term: String, input: String, expected: String) {
        #expect(VocabularyReplacer(entries: [VocabularyEntry(term: term)]).apply(to: input) == expected)
    }

    /// Re-casing these would corrupt ordinary speech: "go home", "a swift reply", "tell us".
    @Test("Never re-cases plain words or all-capital acronyms", arguments: [
        ("Go", "let's go home"),
        ("Swift", "a swift reply"),
        ("Visual Studio Code", "a visual studio code editor"),
        ("US", "tell us about it"),
        ("IT", "is it working"),
        ("NASA", "nasa photos"),
        // A number has no casing, so it does not make the plain word next to it distinctive.
        ("Go 2", "I'd go 2 more rounds"),
        ("Swift 6", "a swift 6 hours"),
        ("Chapter 11", "see chapter 11"),
    ])
    func leavesPlainTermsAlone(term: String, input: String) {
        #expect(VocabularyReplacer(entries: [VocabularyEntry(term: term)]).apply(to: input) == input)
    }

    @Test func aDistinctiveTermDoesNotMatchInsideAWord() {
        let replacer = VocabularyReplacer(entries: [VocabularyEntry(term: "GitHub")])
        #expect(replacer.apply(to: "githubber and githubs") == "githubber and githubs")
    }
}
