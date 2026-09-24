import Shared
import SpokenCommands
import Testing

@Suite("AddressCommand")
struct AddressCommandTests {
    private let protector = PhraseProtector(matchers: [AddressCommand()])

    @Test("Writes spoken addresses", arguments: [
        ("email me at john dot smith at example dot com", "email me at john.smith@example.com"),
        ("Email me at john.smith at example.com.", "Email me at john.smith@example.com."),
        ("Send it to support at example.com please.", "Send it to support@example.com please."),
        ("The pricing is on example.com slash pricing.", "The pricing is on example.com/pricing."),
        ("visit w w w dot example dot org", "visit www.example.org"),
        ("see example dot co dot uk forward slash about", "see example.co.uk/about"),
        ("My email is Jane underscore Doe at Example dot com", "My email is jane_doe@example.com"),
        ("reach me at sam42 at example dot io", "reach me at sam42@example.io"),
        ("we're looking at acme dot com", "we're looking at acme.com"),
        ("(docs at example.com/start slash install)", "(docs at example.com/start/install)"),
        ("email support at example.com", "email support@example.com"),
    ])
    func writesAddresses(spoken: String, expected: String) {
        #expect(protector.protect(spoken).expanded == expected)
    }

    @Test("Leaves ordinary speech and written addresses as they are", arguments: [
        "look at example.com",
        "contact us at example dot com later",
        "the dot com bubble burst",
        "meet at 5.30 tomorrow",
        "I read the readme.md at work",
        "Go to www.example.org.",
        "polka dot dress",
        "info at example.com",
    ])
    func leavesOrdinarySpeech(spoken: String) {
        let expanded = protector.protect(spoken).expanded
        if spoken == "contact us at example dot com later" {
            #expect(expanded == "contact us at example.com later", "the domain is written, the at stays")
        } else {
            #expect(expanded == spoken)
        }
    }

    @Test func hidesTheAddressFromTheModel() {
        let protected = protector.protect("email support at example dot com.")
        #expect(protected.text == "email ⟦S1⟧.")
        #expect(protected.placeholders.first?.expansion == "support@example.com")
        #expect(protected.placeholders.first?.spoken == "support at example dot com")
        #expect(protected.placeholders.first?.role == .content)
    }
}

@Suite("SpokenCommands")
struct SpokenCommandsTests {
    @Test func commandsWorkTogether() {
        let spoken = "Hi team emoji wave new paragraph is the build green question mark email me at sam at example dot com"
        let protected = PhraseProtector(matchers: SpokenCommands.matchers(multiline: true)).protect(spoken)
        #expect(protected.text == "Hi team ⟦S1⟧ ⟦S2⟧ is the build green? Email me at ⟦S3⟧")
        #expect(SpokenCommands.tidyLineBreaks(protected.expanded)
            == "Hi team \u{1F44B}\n\nIs the build green? Email me at sam@example.com")
    }
}
