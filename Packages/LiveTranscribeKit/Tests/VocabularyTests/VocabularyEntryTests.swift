import Foundation
import Testing
import Vocabulary

@Suite("VocabularyEntry")
struct VocabularyEntryTests {
    @Test func sanitizingTrimsAndCollapsesWhitespace() {
        let entry = VocabularyEntry(term: "  Visual   Studio Code\n", spokenVariants: ["  v s   code "])
        let sanitized = entry.sanitized()
        #expect(sanitized.term == "Visual Studio Code")
        #expect(sanitized.spokenVariants == ["v s code"])
        #expect(sanitized.id == entry.id)
    }

    @Test func sanitizingDropsEmptyRepeatedAndTermVariants() {
        let entry = VocabularyEntry(
            term: "Nerdstorm",
            spokenVariants: ["nerd storm", "", "   ", "...", "Nerd Storm.", "NERDSTORM", "nerdstorm!", "nerd store"]
        )
        #expect(entry.sanitized().spokenVariants == ["nerd storm", "nerd store"])
    }

    @Test func sanitizingKeepsTheFirstSpellingOfARepeatedVariant() {
        let entry = VocabularyEntry(term: "GitHub", spokenVariants: ["Git hub", "git hub", "git-hub"])
        #expect(entry.sanitized().spokenVariants == ["Git hub"])
    }

    @Test func entriesRoundTripThroughJSON() throws {
        let entry = VocabularyEntry(term: "Nerdstorm", spokenVariants: ["nerd storm"])
        let data = try JSONEncoder().encode(entry)
        #expect(try JSONDecoder().decode(VocabularyEntry.self, from: data) == entry)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["id", "term", "spokenVariants"])
    }

    /// A term typed into the file by hand often has no variants; it must not make the file corrupt.
    @Test func missingVariantsDecodeAsNone() throws {
        let json = #"{"id": "6F9619FF-8B86-D011-B42D-00C04FC964FF", "term": "Nerdstorm"}"#
        let entry = try JSONDecoder().decode(VocabularyEntry.self, from: Data(json.utf8))
        #expect(entry.term == "Nerdstorm")
        #expect(entry.spokenVariants.isEmpty)
        #expect(entry.id == UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF"))
    }

    /// Without a stored id, every read would invent a new one and delete(id:) could never match.
    @Test("An entry without an id or a term does not decode", arguments: [
        #"{"term": "Nerdstorm", "spokenVariants": []}"#,
        #"{"id": "6F9619FF-8B86-D011-B42D-00C04FC964FF", "spokenVariants": ["nerd storm"]}"#,
    ])
    func requiredFieldsMustBePresent(json: String) {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(VocabularyEntry.self, from: Data(json.utf8))
        }
    }
}

@Suite("VocabularyValidator")
struct VocabularyValidatorTests {
    @Test func returnsTheSanitizedEntries() throws {
        let entries = [
            VocabularyEntry(term: " GitHub ", spokenVariants: ["git hub", "github"]),
            VocabularyEntry(term: "Nerdstorm", spokenVariants: ["nerd storm"]),
        ]
        #expect(try VocabularyValidator.validated(entries) == entries.map { $0.sanitized() })
        #expect(try VocabularyValidator.validated(entries)[0].spokenVariants == ["git hub"])
    }

    @Test("Rejects invalid vocabularies", arguments: [
        ([VocabularyEntry(term: "   ")], VocabularyError.emptyTerm),
        ([VocabularyEntry(term: "...")], VocabularyError.emptyTerm),
        ([VocabularyEntry(term: "GitHub"), VocabularyEntry(term: " github")], VocabularyError.duplicateTerm("github")),
        (
            [
                VocabularyEntry(term: "Nerdstorm", spokenVariants: ["nerd storm"]),
                VocabularyEntry(term: "NerdStore", spokenVariants: ["Nerd Storm."]),
            ],
            VocabularyError.conflictingVariant(variant: "Nerd Storm.", firstTerm: "Nerdstorm", secondTerm: "NerdStore")
        ),
        (
            [VocabularyEntry(term: "Go"), VocabularyEntry(term: "Golang", spokenVariants: ["go"])],
            VocabularyError.conflictingVariant(variant: "go", firstTerm: "Go", secondTerm: "Golang")
        ),
        (
            [VocabularyEntry(term: "Golang", spokenVariants: ["go"]), VocabularyEntry(term: "Go")],
            VocabularyError.conflictingVariant(variant: "Go", firstTerm: "Golang", secondTerm: "Go")
        ),
        (
            [
                VocabularyEntry(term: "Nerdstorm", spokenVariants: ["nerd storm"]),
                VocabularyEntry(term: "Alpha"),
                VocabularyEntry(term: "NerdStore", spokenVariants: ["nerd store", "nerd-storm"]),
            ],
            VocabularyError.conflictingVariant(variant: "nerd-storm", firstTerm: "Nerdstorm", secondTerm: "NerdStore")
        ),
    ])
    func rejects(entries: [VocabularyEntry], expected: VocabularyError) {
        #expect(throws: expected) {
            try VocabularyValidator.validated(entries)
        }
    }

    /// "C++" and "C#" are both the word "c" to the matcher, but they are different terms: only
    /// exact spellings (ignoring case) make a duplicate term.
    @Test func termsThatDifferOnlyInPunctuationAreDistinct() throws {
        let entries = [
            VocabularyEntry(term: "C++", spokenVariants: ["c plus plus"]),
            VocabularyEntry(term: "C#", spokenVariants: ["c sharp"]),
            VocabularyEntry(term: "C"),
            VocabularyEntry(term: "Nerd Storm"),
            VocabularyEntry(term: "Nerd-Storm"),
        ]
        #expect(try VocabularyValidator.validated(entries) == entries)
    }

    @Test func errorsDescribeTheProblemForTheUser() {
        #expect(VocabularyError.emptyTerm.errorDescription == "Every vocabulary entry needs a word or name.")
        #expect(VocabularyError.duplicateTerm("GitHub").errorDescription == "\u{201C}GitHub\u{201D} is already in your vocabulary.")
        let conflict = VocabularyError.conflictingVariant(variant: "go", firstTerm: "Go", secondTerm: "Golang")
        #expect(conflict.errorDescription == "\u{201C}go\u{201D} can\u{2019}t stand for both \u{201C}Go\u{201D} and \u{201C}Golang\u{201D}.")
    }
}
