@testable import Cleanup
import Testing

@Suite("PlaceholderAliases")
struct PlaceholderAliasesTests {
    @Test func theModelSeesAWordForEachToken() {
        let aliases = PlaceholderAliases(tokens: ["⟦S1⟧", "⟦S2⟧"], text: "send ⟦S1⟧ to ⟦S2⟧")
        #expect(aliases.aliases == ["S1", "S2"])
        #expect(aliases.aliased("send ⟦S1⟧ to ⟦S2⟧") == "send S1 to S2")
    }

    @Test func anAliasIsNeverAWordAlreadyInTheText() {
        let aliases = PlaceholderAliases(tokens: ["⟦S1⟧"], text: "fill in the s1 form and send ⟦S1⟧")
        #expect(aliases.aliases == ["T1"])
        #expect(aliases.restored("Fill in the S1 form and send T1.") == "Fill in the S1 form and send ⟦S1⟧.")
    }

    @Test func withNoFreeLetterTheModelSeesTheTokens() {
        let aliases = PlaceholderAliases(tokens: ["⟦S1⟧"], text: "S1 T2 P3 Q4 Z5 ⟦S1⟧")
        #expect(aliases.aliases == ["⟦S1⟧"])
        #expect(aliases.restored("S1 T2 P3 Q4 Z5 ⟦S1⟧") == "S1 T2 P3 Q4 Z5 ⟦S1⟧")
    }

    @Test func restoresWholeWordsInAnyCase() {
        let aliases = PlaceholderAliases(tokens: ["⟦S1⟧", "⟦S2⟧"], text: "send ⟦S1⟧ to ⟦S2⟧")
        #expect(aliases.restored("Send s1 to S2's desk.") == "Send ⟦S1⟧ to ⟦S2⟧'s desk.")
    }

    @Test func anAliasInsideALongerWordIsNotRestored() {
        let tokens = (1...12).map { "⟦S\($0)⟧" }
        let aliases = PlaceholderAliases(tokens: tokens, text: tokens.joined(separator: " "))
        let restored = aliases.restored(aliases.aliases.reversed().joined(separator: " "))
        #expect(restored == tokens.reversed().joined(separator: " "))
    }

    /// The guard counts tokens, so leaving these as words makes it reject the output.
    @Test func aDroppedOrRepeatedAliasIsLeftForTheGuard() {
        let aliases = PlaceholderAliases(tokens: ["⟦S1⟧", "⟦S2⟧"], text: "send ⟦S1⟧ to ⟦S2⟧")
        #expect(aliases.restored("Send S1 to S1.") == "Send S1 to S1.")
        #expect(aliases.restored("Send it.") == "Send it.")
    }

    @Test func withoutTokensNothingChanges() {
        let aliases = PlaceholderAliases(tokens: [], text: "send it")
        #expect(aliases.aliases.isEmpty)
        #expect(aliases.aliased("send it") == "send it")
        #expect(aliases.restored("Send S1.") == "Send S1.")
    }
}
