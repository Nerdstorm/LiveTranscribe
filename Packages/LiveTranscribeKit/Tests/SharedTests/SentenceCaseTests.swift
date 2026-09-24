import Shared
import Testing

@Suite("SentenceCase")
struct SentenceCaseTests {
    @Test("Capitalises the first word unless it is written with capitals already", arguments: [
        ("so we ship", "So we ship"),
        ("  so we ship", "  So we ship"),
        ("\"so we ship\"", "\"So we ship\""),
        ("(maybe) later", "(Maybe) later"),
        ("élan", "Élan"),
        ("iPhone sales", "iPhone sales"),
        ("eBay listing", "eBay listing"),
        ("2nd floor", "2nd floor"),
        ("Already capital", "Already capital"),
        ("\u{1F44B} hi", "\u{1F44B} hi"),
        ("", ""),
    ])
    func capitalizesTheFirstWord(text: String, expected: String) {
        #expect(SentenceCase.capitalizingFirstWord(text) == expected)
    }
}
