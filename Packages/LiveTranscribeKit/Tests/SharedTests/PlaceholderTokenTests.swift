import Shared
import Testing

@Suite("PlaceholderToken")
struct PlaceholderTokenTests {
    @Test func tokensAreNumberedFromOne() {
        #expect(PlaceholderToken.make(index: 1) == "⟦S1⟧")
        #expect(PlaceholderToken.make(index: 12) == "⟦S12⟧")
    }

    @Test func countsOpeningBracketsWholeOrDamaged() {
        #expect(PlaceholderToken.openingCount(in: "Send ⟦S1⟧ and ⟦S2⟧.") == 2)
        #expect(PlaceholderToken.openingCount(in: "Send ⟦S 1 and more") == 1)
        #expect(PlaceholderToken.openingCount(in: "No tokens [S1] here") == 0)
        #expect(PlaceholderToken.closingCount(in: "Send S1⟧ and ⟦S2⟧.") == 2)
    }

    @Test func countsOccurrencesOfOneToken() {
        #expect(PlaceholderToken.occurrences(of: "⟦S1⟧", in: "⟦S1⟧ then ⟦S1⟧ and ⟦S11⟧") == 2)
        #expect(PlaceholderToken.occurrences(of: "⟦S2⟧", in: "⟦S1⟧") == 0)
        #expect(PlaceholderToken.occurrences(of: "", in: "anything") == 0)
    }
}
