import Foundation
import Shared
import SpokenCommands
import Testing

@Suite("EmojiCommand")
struct EmojiCommandTests {
    private let protector = PhraseProtector(matchers: [EmojiCommand()])

    private func output(_ spoken: String) -> String {
        protector.protect(spoken).expanded
    }

    @Test("Inserts an emoji said by name", arguments: [
        ("hi emoji fireworks", "hi \u{1F386}"),
        ("Hi emoji fireworks.", "Hi \u{1F386}."),
        ("Thanks so much Heart Emoji.", "Thanks so much \u{2764}\u{FE0F}."),
        ("Great job emoji party popper see you tomorrow", "Great job \u{1F389} see you tomorrow"),
        ("That's hilarious emoji face with tears of joy", "That's hilarious \u{1F602}"),
        ("See you soon smiley face emoji", "See you soon \u{1F642}"),
        ("emoji thumbs up", "\u{1F44D}"),
        ("Launch day emoji rocket emoji rocket", "Launch day \u{1F680} \u{1F680}"),
        ("happy birthday emoji cake", "happy birthday \u{1F382}"),
        ("good morning sun emoji", "good morning \u{2600}\u{FE0F}"),
        ("emoji sparkler", "\u{1F387}"),
        ("so many emoji hearts", "so many \u{2764}\u{FE0F}"),
        ("look emoji crystal ball", "look \u{1F52E}"),
        ("(emoji wave)", "(\u{1F44B})"),
    ])
    func insertsEmoji(spoken: String, expected: String) {
        #expect(output(spoken) == expected)
    }

    @Test("Leaves speech about emoji as said", arguments: [
        "I love emoji",
        "I'm happy emoji",
        "Send an emoji party invite",
        "the fire emoji is overused",
        "the emoji picker is broken",
        "Emoji. Fireworks are loud",
        "emoji",
        "We use emoji every day",
    ])
    func leavesSpeechAboutEmoji(spoken: String) {
        #expect(output(spoken) == spoken)
    }

    @Test func hidesTheEmojiFromTheModel() {
        let protected = protector.protect("hi emoji fireworks!")
        #expect(protected.text == "hi ⟦S1⟧!")
        #expect(protected.placeholders.first?.role == .content)
        #expect(protected.placeholders.first?.spoken == "emoji fireworks")
        #expect(protected.placeholders.first?.trigger == "emoji fireworks")
    }
}

@Suite("EmojiNames")
struct EmojiNamesTests {
    @Test func everyCommonNameIsOneEmojiAndNamesOnlyOne() {
        var seen: Set<String> = []
        for (name, emoji) in EmojiNames.commonNames {
            #expect(emoji.count == 1, "\(name) is one character")
            #expect(emoji.unicodeScalars.first?.properties.isEmoji == true, "\(name) is an emoji")
            #expect(EditDistance.normalize(name) == name, "\(name) is written as normalised speech")
            #expect(seen.insert(name).inserted)
        }
        #expect(EmojiNames.commonNames.count > 300)
    }

    @Test func fallsBackToUnicodeNamesAndTheSingular() {
        let names = EmojiNames.standard
        #expect(names.emoji(for: ["crystal", "ball"]) == "\u{1F52E}")
        #expect(names.emoji(for: ["black", "sun", "with", "rays"]) == "\u{2600}\u{FE0F}", "text-style emoji get emoji presentation")
        #expect(names.emoji(for: ["balloons"]) == "\u{1F388}")
        #expect(names.emoji(for: ["fireworks"]) == "\u{1F386}")
    }

    @Test("Names that are not emoji give nothing", arguments: [
        ["latin", "small", "letter", "a"], ["digit", "one"], ["and"], ["we"], ["the", "party"], [], ["copyright", "sign"],
    ])
    func rejectsNonEmoji(words: [String]) {
        #expect(EmojiNames.standard.emoji(for: words) == nil)
    }

    @Test func customNamesCanTurnOffUnicodeNames() {
        let names = EmojiNames(aliases: ["yay": "\u{1F389}"], usesUnicodeNames: false)
        #expect(names.emoji(for: ["yay"]) == "\u{1F389}")
        #expect(names.emoji(for: ["rocket"]) == nil)
    }
}
