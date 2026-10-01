import Foundation
import Shared

/// Deep's layout examples beyond ``DeepExampleGenerator``'s first three: lists of two to six
/// items, series that stay in their sentence, email bodies, placeholder tokens and corrections
/// inside a mention. The frames are in ``DeepLayoutFrames``.
///
/// Conventions, the ones of `Training/eval/layout.jsonl`: a bulleted list is the intro and a
/// colon, then "- Item" lines with a capital and no full stop; a numbered one has "1. Item."
/// lines; text after a list follows a blank line; a greeting has a line and a blank line to
/// itself. Two things are a list only after a colon the speaker said.
extension DeepExampleGenerator {
    // MARK: - Lists

    /// The pieces of a list example: the intro sentence, the items, and whether their order matters.
    private struct ListParts {
        var intro: String
        var items: [String]
        var ordered: Bool
    }

    /// "Two things I need: the floor plan and the contact." → a list of two, in a field that takes
    /// several lines, or the sentence in one that takes one.
    mutating func listTwo() -> DeepExample {
        let multiline = !chance(0.25)
        return listExample(.listTwo, count: 2, multiline: multiline, streaming: false)
    }

    /// Three to six items, bulleted or numbered.
    mutating func listMany() -> DeepExample {
        let multiline = !chance(0.2)
        return listExample(.listMany, count: Int.random(in: 3...6, using: &rng), multiline: multiline, streaming: true)
    }

    private mutating func listExample(
        _ category: DeepExample.Category,
        count: Int,
        multiline: Bool,
        streaming: Bool
    ) -> DeepExample {
        let parts = listParts(count: count, ordered: chance(0.35))
        let frame = frame(around: parts, multiline: multiline, allowGreeting: true, allowStreaming: streaming)
        return dictation(
            category, said: frame.said, written: frame.written, lead: false, multiline: multiline,
            streaming: frame.streaming
        )
    }

    /// A list's words around it: an opening sentence on the intro's line, or a greeting line, and a
    /// closing sentence after a blank line. A text with any of them is written with its
    /// punctuation, as a recognizer that writes the colon does.
    private mutating func frame(
        around parts: ListParts,
        multiline: Bool,
        allowGreeting: Bool,
        allowStreaming: Bool,
        allowOpener: Bool = true
    ) -> (said: String, written: String, streaming: Bool) {
        let test = split == .test
        let spoken = spokenItems(parts)
        var said = "\(parts.intro): \(spoken)."
        var written = multiline ? Self.laidOut(parts) : said
        var punctuated = false
        if allowOpener, chance(0.3) {
            let opener = sentence(fill(pick(test ? DeepLayoutFrames.openersTest : DeepLayoutFrames.openersTrain)))
            said = "\(opener) \(said)"
            written = "\(opener) \(written)"
            punctuated = true
        } else if allowGreeting, chance(0.18) {
            let greeting = "\(pick(DeepFrames.greetings)) \(pick(DeepPools.names(split: split)))"
            said = "\(greeting), \(Self.lowercasedFirst(said))"
            written = multiline ? "\(greeting),\n\n\(written)" : "\(greeting), \(Self.lowercasedFirst(written))"
            punctuated = true
        }
        if chance(0.35) {
            let closer = sentence(fill(pick(test ? DeepLayoutFrames.closersTest : DeepLayoutFrames.closersTrain)))
            said += " \(closer)"
            written += multiline ? "\n\n\(closer)" : " \(closer)"
            punctuated = true
        }
        return (said, written, allowStreaming && !punctuated)
    }

    /// The intro and items of a list, from a pack.
    private mutating func listParts(count: Int, ordered: Bool) -> ListParts {
        let test = split == .test
        let packs = ordered
            ? (test ? DeepLayoutFrames.stepPacksTest : DeepLayoutFrames.stepPacksTrain)
            : (test ? DeepLayoutFrames.bulletPacksTest : DeepLayoutFrames.bulletPacksTrain)
        let pack = pick(packs)
        let intro = sentence(fill(Self.counted(pick(pack.intros), count: count)))
        let chosen = ordered ? Array(pack.items.prefix(count)) : distinct(count, from: pack.items)
        return ListParts(intro: intro, items: chosen.map { fill($0) }, ordered: ordered)
    }

    /// `intro` with `{count}` and `{few}` filled for `count` items.
    static func counted(_ intro: String, count: Int) -> String {
        let words = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight"]
        let few = count == 2 ? "a couple of" : (count <= 4 ? "a few" : "several")
        return intro.replacingOccurrences(of: "{count}", with: words[min(count, words.count - 1)])
            .replacingOccurrences(of: "{few}", with: few)
    }

    /// The items as the speaker says them: "A, B and C", or, for an ordered list, each after the word
    /// that marks its place.
    private mutating func spokenItems(_ parts: ListParts) -> String {
        guard parts.ordered else { return join(parts.items) }
        switch Int.random(in: 0..<3, using: &rng) {
        case 0:
            // "first A, then B, then C", the last sometimes "finally".
            return parts.items.enumerated().map { index, item in
                let last = index == parts.items.count - 1
                return index == 0 ? "first \(item)" : (last && chance(0.4) ? "finally \(item)" : "then \(item)")
            }.joined(separator: ", ")
        case 1:
            return parts.items.enumerated().map { "\(Self.ordinals[$0.offset]) \($0.element)" }.joined(separator: ", ")
        default:
            return join(parts.items, conjunction: "then")
        }
    }

    private static let ordinals = ["first", "second", "third", "fourth", "fifth", "sixth"]
    private static let numberWords = ["One,", "Two,", "Three,", "Four,", "Five,", "Six,"]

    /// Steps counted "One, A. Two, B.": Deep's check keeps the numbers a speaker says that way, so
    /// the text stays as said and the layout rules number it.
    private mutating func countedSteps() -> (said: String, written: String) {
        let parts = listParts(count: Int.random(in: 2...5, using: &rng), ordered: true)
        let counted = parts.items.enumerated().map { "\(Self.numberWords[$0.offset]) \($0.element)." }.joined(separator: " ")
        let text = "\(parts.intro): \(counted)"
        return (text, text)
    }

    /// "A, B and C"; "A and B" for two; sometimes with the comma before "and".
    mutating func join(_ items: [String], conjunction: String = "and") -> String {
        guard let last = items.last, items.count > 1 else { return items.first ?? "" }
        if items.count == 2 { return "\(items[0]) \(conjunction) \(last)" }
        let comma = conjunction == "and" && chance(0.15) ? "," : ""
        return items.dropLast().joined(separator: ", ") + "\(comma) \(conjunction) \(last)"
    }

    /// The list as written: bulleted, or numbered when the order matters.
    private static func laidOut(_ parts: ListParts) -> String {
        let lines = parts.items.enumerated().map { index, item in
            parts.ordered ? "\(index + 1). \(capitalisedFirst(item))." : "- \(capitalisedFirst(item))"
        }
        return "\(parts.intro):\n" + lines.joined(separator: "\n")
    }

    // MARK: - Series and colons that stay

    /// A series inside a sentence, or a colon that introduces no list: every word stays.
    mutating func series() -> DeepExample {
        let test = split == .test
        if chance(0.12) {
            let counted = countedSteps()
            return dictation(.series, said: counted.said, written: counted.written, lead: false, multiline: chance(0.6), streaming: false)
        }
        var said: [String] = []
        var written: [String] = []
        for _ in 0..<(chance(0.25) ? 2 : 1) {
            let text: String
            if chance(0.2) {
                text = sentence(fill(pick(test ? DeepLayoutFrames.colonSentencesTest : DeepLayoutFrames.colonSentencesTrain)))
            } else {
                text = sentence(fill(seriesFilled(pick(test ? DeepLayoutFrames.seriesFramesTest : DeepLayoutFrames.seriesFramesTrain))))
            }
            said.append(text)
            written.append(text)
        }
        // Text with a colon keeps it: a recognizer that writes one writes it here too.
        return dictation(
            .series, said: said.joined(separator: " "), written: written.joined(separator: " "),
            multiline: chance(0.6), streaming: !said.contains { $0.contains(":") }
        )
    }

    /// `frame` with its `{series:key}` and `{pair:key}` slots filled from the series pools.
    private mutating func seriesFilled(_ frame: String) -> String {
        let pools = split == .test ? DeepLayoutFrames.seriesPoolsTest : DeepLayoutFrames.seriesPoolsTrain
        var text = frame
        while let range = text.range(of: #"\{(series|pair):[A-Za-z0-9_-]+\}"#, options: .regularExpression) {
            let slot = text[range].dropFirst().dropLast().split(separator: ":")
            let values = pools[String(slot[1])] ?? []
            guard !values.isEmpty else { return text.replacingCharacters(in: range, with: "it") }
            let count = slot[0] == "pair" ? 2 : Int.random(in: 2...4, using: &rng)
            text.replaceSubrange(range, with: join(distinct(count, from: values)))
        }
        return text
    }

    // MARK: - Email bodies

    /// The body of an email, which the app sends without its greeting and sign-off: a paragraph that
    /// stays one, a list that is laid out, a correction resolved, or cue words that stay.
    mutating func body() -> DeepExample {
        let test = split == .test
        switch Int.random(in: 0..<20, using: &rng) {
        case 0..<7:
            let (said, written) = Self.alternatives(in: fill(pick(test ? DeepLayoutFrames.bodiesTest : DeepLayoutFrames.bodiesTrain)))
            return dictation(.body, said: sentence(said), written: sentence(written), lead: false, multiline: true, letterBody: true)
        case 7..<15:
            let ordered = chance(0.2)
            let count = chance(0.3) ? 2 : Int.random(in: 3...5, using: &rng)
            let parts = listParts(count: count, ordered: ordered)
            let around = frame(around: parts, multiline: true, allowGreeting: false, allowStreaming: true)
            return dictation(
                .body, said: around.said, written: around.written, lead: false, multiline: true, letterBody: true,
                streaming: around.streaming && count > 2
            )
        case 15..<18:
            var example = sameSentence()
            if chance(0.5) {
                // A correction across sentences that no check can tell is about the phrase is left out.
                let validator = DeepExampleValidator()
                for _ in 0..<8 {
                    let candidate = crossSentence()
                    if validator.problems(in: candidate).isEmpty { example = candidate; break }
                }
            }
            example.category = .body
            example.multiline = true
            example.letterBody = true
            return example
        default:
            let frames = test ? DeepFrames.controlTest + Frames.controlTest : DeepFrames.controlTrain + Frames.controlTrain
            var example = kept(.body, from: frames)
            example.multiline = true
            example.letterBody = true
            return example
        }
    }

    // MARK: - Placeholders

    /// Text with placeholder tokens, which stay where they stand: an emoji after a sentence or
    /// inside one, a link, two or three in a row, or the markers of a spoken list, which the layout
    /// rules lay out and so keep the text one paragraph.
    mutating func placeholder() -> DeepExample {
        firstValid { $0.placeholderOnce() }
    }

    private mutating func placeholderOnce() -> DeepExample {
        let test = split == .test
        if chance(0.25) {
            let (said, written) = Self.alternatives(in: fill(pick(test ? DeepLayoutFrames.markerFramesTest : DeepLayoutFrames.markerFramesTrain)))
            let (tokenSaid, tokenWritten) = (Self.tokens(in: said, marker: "{mark}"), Self.tokens(in: written, marker: "{mark}"))
            return dictation(
                .placeholder, said: tokenSaid, written: tokenWritten, lead: false, multiline: false, letterBody: chance(0.4)
            )
        }
        let (said, written) = Self.alternatives(in: fill(pick(test ? DeepLayoutFrames.tokenFramesTest : DeepLayoutFrames.tokenFramesTrain)))
        var spoken = Self.tokens(in: said, marker: "{tok}")
        // A recognizer writes no full stop before an emoji it hears after a sentence.
        if chance(0.5) {
            for token in PlaceholderToken.tokens(in: spoken) {
                spoken = spoken.replacingOccurrences(of: ". \(token)", with: " \(token)")
            }
        }
        let multiline = chance(0.7)
        return dictation(
            .placeholder, said: spoken, written: Self.tokens(in: written, marker: "{tok}"),
            lead: chance(0.2), multiline: multiline, letterBody: multiline && chance(0.25)
        )
    }

    /// `text` with each `marker` replaced by a token, numbered from 1 in order.
    static func tokens(in text: String, marker: String) -> String {
        var result = text
        var index = 0
        while let range = result.range(of: marker) {
            index += 1
            result.replaceSubrange(range, with: PlaceholderToken.make(index: index))
        }
        return result
    }

    /// The first of a few tries that the validator accepts, so a shape the guard cannot tell from an
    /// error (a cue it reads as part of the text) is left out, not trained on.
    private mutating func firstValid(_ make: (inout Self) -> DeepExample) -> DeepExample {
        let validator = DeepExampleValidator()
        var example = make(&self)
        for _ in 0..<8 where !validator.problems(in: example).isEmpty { example = make(&self) }
        return example
    }

    // MARK: - Mentions

    /// A correction said inside a mention, which restates the retracted word after "not": "Tools like
    /// Docker, sorry, not Docker, Kubernetes are popular." → "Tools like Kubernetes are popular."
    /// And an ordinary contrast, "three, not four", which stays.
    mutating func mention() -> DeepExample {
        firstValid { $0.mentionOnce() }
    }

    private mutating func mentionOnce() -> DeepExample {
        let test = split == .test
        if chance(0.25) {
            let frame = pick(test ? DeepLayoutFrames.contrastFramesTest : DeepLayoutFrames.contrastFramesTrain)
            let pools = test ? DeepLayoutFrames.contrastPoolsTest : DeepLayoutFrames.contrastPoolsTrain
            let text = sentence(fill(keyed(frame, slots: ["A", "B"], pools: pools)))
            return dictation(.mention, said: text, written: text, multiline: chance(Self.multilineShare))
        }
        let cue = pick(Self.mentionCues)
        let said: String
        let written: String
        if chance(0.7) {
            let frame = fill(pick(test ? DeepLayoutFrames.mentionFramesTest : DeepLayoutFrames.mentionFramesTrain))
            let pools = test ? DeepLayoutFrames.mentionPoolsTest : DeepLayoutFrames.mentionPoolsTrain
            guard let (key, range) = Self.slot(named: "X", in: frame), let values = pools[key], values.count > 1 else {
                return sameSentence()
            }
            let old = pick(values)
            let new = pick(values.filter { $0 != old })
            said = sentence(frame.replacingCharacters(in: range, with: "\(old), \(cue), not \(old), \(new)"))
            written = sentence(frame.replacingCharacters(in: range, with: new))
        } else {
            let frame = pick(test ? Frames.correctionTest : Frames.correctionTrain)
            let (old, new) = twoValues(frame.slot)
            let filled = fill(frame.text)
            said = sentence(filled.replacingOccurrences(of: "{X}", with: "\(old), \(cue), not \(old), \(new)"))
            written = sentence(filled.replacingOccurrences(of: "{X}", with: new))
        }
        return dictation(.mention, said: said, written: written, multiline: chance(Self.multilineShare))
    }

    /// Cues that only ever take something back, which a speaker follows with "not" and the word again.
    static let mentionCues = ["sorry", "sorry", "I mean", "no wait", "no, sorry", "make that", "or rather"]

    /// The key and range of the slot `{name:key}` in `frame`.
    private static func slot(named name: String, in frame: String) -> (String, Range<String.Index>)? {
        guard let range = frame.range(of: "\\{\(name):[A-Za-z0-9_-]+\\}", options: .regularExpression) else { return nil }
        let key = frame[range].dropFirst().dropLast().split(separator: ":")[1]
        return (String(key), range)
    }

    /// `frame` with the `{A:key}` and `{B:key}` slots filled with different values of the key's pool.
    private mutating func keyed(_ frame: String, slots: [String], pools: [String: [String]]) -> String {
        var text = frame
        var used: [String: [String]] = [:]
        for name in slots {
            while let (key, range) = Self.slot(named: name, in: text) {
                let values = (pools[key] ?? ["it"]).filter { !(used[key] ?? []).contains($0) }
                let value = values.isEmpty ? "it" : pick(values)
                used[key, default: []].append(value)
                text.replaceSubrange(range, with: value)
            }
        }
        return text
    }
}
