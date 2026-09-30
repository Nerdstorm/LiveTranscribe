import Foundation
import Shared

/// Builds synthetic examples for Deep's adapter from ``DeepFrames``, reproducibly from a seed.
///
/// Each example is a dictation as a recognizer would write it and the text Deep should show:
/// corrections resolved across sentences and read as meant when garbled, grammar and misheard
/// words fixed, emails and lists laid out in a field that takes several lines and kept to one
/// paragraph in a field that doesn't; and, as often, text in which every word must stay: cue
/// words used in their ordinary sense, facts, times said outside a correction, names the adapter
/// has never seen, and text that is already right. Some raw texts are lowercase and unpunctuated
/// like a streaming recognizer's, the rest cased like Parakeet's. Medium's own examples
/// (``mediumExamples(from:)``) are added to these, so Deep keeps what Medium does.
///
/// No example comes from anyone's dictation history.
public struct DeepExampleGenerator: Sendable {
    public typealias Counts = [DeepExample.Category: Int]

    public static func counts(for split: DataSplit) -> Counts {
        let train: Counts = [
            .crossSentence: 800, .malformed: 650, .sameSentence: 450, .control: 650, .facts: 300,
            .grammar: 550, .recognition: 450, .layout: 500, .oneLine: 250, .unchanged: 250,
        ]
        switch split {
        case .train: return train
        case .valid: return train.mapValues { max($0 / 10, 10) }
        case .test: return train.mapValues { max($0 / 8, 20) }
        }
    }

    /// How many of Medium's own examples (``ExampleGenerator``) go into Deep's training and
    /// validation splits, so the adapter keeps what Medium does: resolving corrections within a
    /// sentence, "scratch that", and keeping cues said in their ordinary sense. Medium's test
    /// split measures that instead, so none go into Deep's.
    public static func mediumCounts(for split: DataSplit) -> ExampleGenerator.Counts {
        switch split {
        case .train: ExampleGenerator.Counts(correction: 600, scratch: 150, control: 300, cleanup: 150, boundary: 60)
        case .valid: ExampleGenerator.Counts(correction: 60, scratch: 15, control: 30, cleanup: 15, boundary: 6)
        case .test: ExampleGenerator.Counts(correction: 0, scratch: 0, control: 0, cleanup: 0, boundary: 0)
        }
    }

    /// Share of raw texts that are lowercase and unpunctuated.
    static let streamingShare = 0.4
    /// Share of examples, outside layout's, in a field that takes several lines: most text written
    /// there is neither an email nor a list, and stays as sentences.
    static let multilineShare = 0.3
    /// Share of examples that carry earlier transcript lines as context.
    static let contextShare = 0.2
    /// Share of examples that open with another sentence, which stays as it is.
    static let leadShare = 0.35

    public let split: DataSplit
    private var rng: SeededGenerator

    public init(split: DataSplit, seed: UInt64) {
        self.split = split
        self.rng = SeededGenerator(seed: seed)
    }

    /// Unique examples for the split. Raw texts in `excluding`, compared ignoring casing and
    /// punctuation, are skipped, which keeps the splits apart.
    public mutating func generate(counts: Counts? = nil, excluding: Set<String> = []) -> [DeepExample] {
        let counts = counts ?? Self.counts(for: split)
        let excluded = Set(excluding.map(EditDistance.normalize))
        var seen = Set<String>()
        var examples: [DeepExample] = []
        for category in DeepExample.Category.allCases {
            let count = counts[category] ?? 0
            var added = 0
            var attempts = 0
            while added < count && attempts < count * 50 {
                attempts += 1
                var example = make(category)
                let normalized = EditDistance.normalize(example.raw)
                guard !excluded.contains(normalized), seen.insert("\(example.multiline) \(normalized)").inserted else { continue }
                if example.context.isEmpty, chance(Self.contextShare) {
                    example.context = contextLines()
                }
                examples.append(example)
                added += 1
            }
        }
        examples.shuffle(using: &rng)
        return examples
    }

    private mutating func make(_ category: DeepExample.Category) -> DeepExample {
        let test = split == .test
        switch category {
        case .crossSentence:
            return crossSentence()
        case .malformed:
            return malformed()
        case .sameSentence:
            return sameSentence()
        case .control:
            return kept(.control, from: test ? DeepFrames.controlTest + Frames.controlTest : DeepFrames.controlTrain + Frames.controlTrain)
        case .facts:
            return kept(.facts, from: test ? DeepFrames.factsTest : DeepFrames.factsTrain)
        case .unchanged:
            return kept(.unchanged, from: test ? DeepFrames.unchangedTest : DeepFrames.unchangedTrain)
        case .grammar:
            return slip(.grammar, from: test ? DeepFrames.grammarTest : DeepFrames.grammarTrain)
        case .recognition:
            return slip(.recognition, from: test ? DeepFrames.recognitionTest : DeepFrames.recognitionTrain)
        case .layout:
            return laidOut(multiline: true)
        case .oneLine:
            return laidOut(multiline: false)
        }
    }

    // MARK: - Corrections

    /// A value taken back in a later sentence: "The plumber is coming on Tuesday. Sorry, on
    /// Wednesday." → "The plumber is coming on Wednesday."
    mutating func crossSentence() -> DeepExample {
        if chance(0.2) { return timeKept(acrossSentences: true) }
        let frame = pick(split == .test ? DeepFrames.crossTest : DeepFrames.crossTrain)
        let (old, new) = twoValues(frame.slot)
        let filled = fill(frame.text)
        let said = "\(sentence(filled.replacingOccurrences(of: "{X}", with: old))) \(pick(DeepFrames.sentenceCues)) \(phrase(for: new, in: filled, slot: frame.slot))."
        return dictation(.crossSentence, said: said, written: sentence(filled.replacingOccurrences(of: "{X}", with: new)))
    }

    /// A correction whose phrase came out garbled, which the speaker meant whole.
    mutating func malformed() -> DeepExample {
        switch Int.random(in: 0..<5, using: &rng) {
        case 0: dayGarble(withDoubt: false)
        case 1: dayGarble(withDoubt: true)
        case 2, 3: strayWords()
        default: missingDay()
        }
    }

    /// A correction of something else in a sentence that says when, whose time stays as said:
    /// "We're migrating the cache, sorry, the frontend next week." → "We're migrating the frontend
    /// next week.", not "the week after next".
    private mutating func timeKept(acrossSentences: Bool) -> DeepExample {
        let frame = pick(split == .test ? DeepFrames.timeKeptTest : DeepFrames.timeKeptTrain)
        let (old, new) = twoValues(frame.slot)
        let filled = fill(frame.text)
        let written = sentence(filled.replacingOccurrences(of: "{X}", with: new))
        if acrossSentences {
            let said = "\(sentence(filled.replacingOccurrences(of: "{X}", with: old))) \(pick(DeepFrames.sentenceCues)) \(new)."
            return dictation(.crossSentence, said: said, written: written)
        }
        let said = sentence(filled.replacingOccurrences(of: "{X}", with: "\(old), \(pick(Cues.correction)), \(new)"))
        return dictation(.sameSentence, said: said, written: written)
    }

    /// "The demo is tomorrow. No, sorry, the after tomorrow." → "The demo is the day after
    /// tomorrow." With `withDoubt`, as part of a longer dictation whose sentence has a slip of
    /// its own, which is fixed too.
    private mutating func dayGarble(withDoubt: Bool) -> DeepExample {
        let test = split == .test
        let garble = pick(test ? DeepFrames.dayGarblesTest : DeepFrames.dayGarblesTrain)
        let cue = pick(Self.strongCues)
        if withDoubt {
            let lead = sentence(fill(pick(test ? DeepFrames.leadTest : DeepFrames.leadTrain)))
            let (doubtSaid, doubtWritten) = Self.alternatives(in: fill(pick(test ? DeepFrames.doubtTest : DeepFrames.doubtTrain)))
            let said = "\(lead) \(sentence(doubtSaid.replacingOccurrences(of: "{X}", with: garble.original))) \(cue) \(garble.said)."
            let written = "\(lead) \(sentence(doubtWritten.replacingOccurrences(of: "{X}", with: garble.written)))"
            return dictation(.malformed, said: said, written: written, lead: false)
        }
        let frame = fill(pick(test ? DeepFrames.whenTest : DeepFrames.whenTrain))
        let said = "\(sentence(frame.replacingOccurrences(of: "{X}", with: garble.original))) \(cue) \(garble.said)."
        return dictation(.malformed, said: said, written: sentence(frame.replacingOccurrences(of: "{X}", with: garble.written)))
    }

    /// "The report goes to Sam. No, sorry, to the to Priya." → "The report goes to Priya."
    private mutating func strayWords() -> DeepExample {
        let item = pick(split == .test ? DeepFrames.strayTest : DeepFrames.strayTrain)
        let (old, new) = twoValues(item.slot)
        let frame = fill(item.frame)
        let said = "\(sentence(frame.replacingOccurrences(of: "{X}", with: old))) \(pick(Self.strongCues)) \(pick(item.stray)) \(new)."
        return dictation(.malformed, said: said, written: sentence(frame.replacingOccurrences(of: "{X}", with: new)))
    }

    /// "She starts on the third of March. Sorry, the of April." → "She starts on the third of April."
    private mutating func missingDay() -> DeepExample {
        let frame = fill(pick(split == .test ? DeepFrames.datesTest : DeepFrames.datesTrain))
        let (old, new) = twoValues(.month)
        let said = "\(sentence(frame.replacingOccurrences(of: "{X}", with: old))) \(pick(Self.strongCues)) the of \(new)."
        return dictation(.malformed, said: said, written: sentence(frame.replacingOccurrences(of: "{X}", with: new)))
    }

    /// Within one sentence, as Medium resolves it: "We need three, sorry, four servers."
    mutating func sameSentence() -> DeepExample {
        if chance(0.25) { return timeKept(acrossSentences: false) }
        if chance(0.12) {
            let pair = pick(split == .test ? Frames.scratchTest : Frames.scratchTrain)
            let kept = sentence(fill(pair.kept))
            let said = sentence("\(fill(pair.dropped)), scratch that, \(Self.lowercasedFirst(kept))")
            return dictation(.sameSentence, said: said, written: kept)
        }
        let frame = pick(split == .test ? Frames.correctionTest : Frames.correctionTrain)
        let (old, new) = twoValues(frame.slot)
        let filled = fill(frame.text)
        let said = sentence(filled.replacingOccurrences(of: "{X}", with: "\(old), \(pick(Cues.correction)), \(new)"))
        return dictation(.sameSentence, said: said, written: sentence(filled.replacingOccurrences(of: "{X}", with: new)))
    }

    /// Cues that only ever take something back, for the garbled phrases: "no" or "actually"
    /// alone may start a new point.
    static let strongCues = ["Sorry,", "No, sorry,", "No, sorry,", "Sorry, I mean", "No, I mean", "I mean,", "Sorry, no,"]

    /// The correction phrase for `value` in `frame`: the value, or with the preposition before its
    /// slot ("on Wednesday"), or with the word after a number ("four chairs").
    private mutating func phrase(for value: String, in frame: String, slot kind: Slot) -> String {
        let words = frame.split(separator: " ").map(String.init)
        guard let slot = words.firstIndex(where: { $0.hasPrefix("{X}") }) else { return value }
        let prepositions: Set<String> = ["on", "at", "in", "to", "by", "for", "from", "with"]
        if slot > 0, prepositions.contains(words[slot - 1].lowercased()), chance(0.5) {
            return "\(words[slot - 1].lowercased()) \(value)"
        }
        if kind == .number, words[slot] == "{X}", slot + 1 < words.count, chance(0.4) {
            return "\(value) \(words[slot + 1].trimmingCharacters(in: .punctuationCharacters))"
        }
        return value
    }

    // MARK: - Text that stays, and slips

    /// Every word stays; only casing and punctuation change, and a word marked `~` is said twice.
    private mutating func kept(_ category: DeepExample.Category, from frames: [String]) -> DeepExample {
        let (said, written) = Self.alternatives(in: fill(pick(frames)))
        return dictation(category, said: sentence(said), written: sentence(written))
    }

    /// A grammar slip or a misheard word, sometimes two in a row.
    private mutating func slip(_ category: DeepExample.Category, from frames: [String]) -> DeepExample {
        var (said, written) = Self.alternatives(in: fill(pick(frames)))
        (said, written) = (sentence(said), sentence(written))
        if chance(0.25) {
            let (moreSaid, moreWritten) = Self.alternatives(in: fill(pick(frames)))
            said += " " + sentence(moreSaid)
            written += " " + sentence(moreWritten)
        }
        return dictation(category, said: said, written: written)
    }

    // MARK: - Layout

    private mutating func laidOut(multiline: Bool) -> DeepExample {
        let category: DeepExample.Category = multiline ? .layout : .oneLine
        let (said, written) = switch Int.random(in: 0..<3, using: &rng) {
        case 0: email(multiline: multiline)
        case 1: list(multiline: multiline)
        default: steps(multiline: multiline)
        }
        return dictation(category, said: said, written: written, lead: false, multiline: multiline)
    }

    /// "Hi Sam, thanks for … Cheers, Priya." → greeting, body and sign-off on their own lines.
    private mutating func email(multiline: Bool) -> (String, String) {
        let greeting = pick(DeepFrames.greetings)
        let addressee = greeting == "Dear" && chance(0.5)
            ? "\(pick(["Mr", "Ms", "Dr"])) \(pick(DeepPools.values(.surname, split: split)))"
            : pick(DeepPools.names(split: split))
        let body = sentence(fill(pick(split == .test ? DeepFrames.bodiesTest : DeepFrames.bodiesTrain)))
        let signOff = pick(DeepFrames.signOffs)
        let sender = pick(DeepPools.names(split: split).filter { $0 != addressee })
        let said = "\(greeting) \(addressee), \(Self.lowercasedFirst(body)) \(signOff), \(sender)."
        return (said, multiline ? "\(greeting) \(addressee),\n\n\(body)\n\n\(signOff),\n\(sender)" : said)
    }

    /// "I need to buy milk, eggs and bread." → the intro, then one bulleted item per line.
    private mutating func list(multiline: Bool) -> (String, String) {
        let (introFrame, kind) = pick(split == .test ? DeepFrames.listIntrosTest : DeepFrames.listIntrosTrain)
        let intro = sentence(fill(introFrame))
        var items: [String] = []
        for item in distinct(Int.random(in: 3...5, using: &rng), from: DeepPools.values(kind, split: split)) {
            items.append(fill(item))
        }
        let joined = items.dropLast().joined(separator: ", ") + " and " + items.last!
        let isClause = ["I ", "We", "Don't", "For ", "This week"].contains { intro.hasPrefix($0) }
        let said = "\(intro)\(isClause ? "" : ":") \(joined)."
        return (said, multiline ? "\(intro):\n" + items.map { "- \(Self.capitalisedFirst($0))" }.joined(separator: "\n") : said)
    }

    /// "The steps are: first open the app, second go to settings, …" → one numbered step per line.
    private mutating func steps(multiline: Bool) -> (String, String) {
        let test = split == .test
        let useTasks = chance(0.3)
        let taskIntros = (test ? DeepFrames.listIntrosTest : DeepFrames.listIntrosTrain).filter { $0.kind == .task }.map(\.intro)
        let intro = useTasks && !taskIntros.isEmpty
            ? sentence(fill(pick(taskIntros)))
            : pick(test ? DeepFrames.stepIntrosTest : DeepFrames.stepIntrosTrain)
        let pool = useTasks && !taskIntros.isEmpty ? DeepPools.values(.task, split: split) : DeepPools.values(.step, split: split)
        var items: [String] = []
        for item in distinct(Int.random(in: 3...5, using: &rng), from: pool) {
            items.append(fill(item))
        }
        let markers: [String]? = chance(0.65) ? pick(DeepFrames.itemMarkers) : nil
        var spoken: [String] = []
        for (index, item) in items.enumerated() {
            let isLast = index == items.count - 1
            if let markers {
                let marker = isLast && markers[1] == "then" && chance(0.5) ? "finally" : markers[index]
                spoken.append("\(isLast && chance(0.5) ? "and " : "")\(marker) \(item)")
            } else {
                spoken.append(isLast ? "then \(item)" : item)
            }
        }
        let said = "\(intro): \(spoken.joined(separator: ", "))."
        let numbered = items.enumerated().map { "\($0.offset + 1). \(Self.capitalisedFirst($0.element))." }
        return (said, multiline ? "\(intro):\n" + numbered.joined(separator: "\n") : said)
    }

    // MARK: - Composing

    /// The example for a dictation: sometimes after a sentence that stays, in a field that takes
    /// several lines or not, and as a streaming or a cased recognizer would write it.
    private mutating func dictation(
        _ category: DeepExample.Category,
        said: String,
        written: String,
        lead: Bool = true,
        multiline: Bool? = nil
    ) -> DeepExample {
        var said = said
        var written = written
        if lead, chance(Self.leadShare) {
            let opening = sentence(fill(pick(split == .test ? DeepFrames.leadTest : DeepFrames.leadTrain)))
            said = "\(opening) \(said)"
            written = "\(opening) \(written)"
        }
        let raw = chance(Self.streamingShare) ? EditDistance.normalize(said) : said
        return DeepExample(
            category: category,
            raw: raw,
            target: written,
            multiline: multiline ?? chance(Self.multilineShare),
            source: "generated"
        )
    }

    private mutating func contextLines() -> [String] {
        let frames = split == .test ? DeepFrames.unchangedTest + DeepFrames.factsTest : DeepFrames.unchangedTrain + DeepFrames.factsTrain
        return (0..<Int.random(in: 1...2, using: &rng)).map { _ in sentence(Self.alternatives(in: fill(pick(frames))).written) }
    }

    /// Replaces every `{kind}` placeholder except `{X}` with a value from its pool.
    private mutating func fill(_ text: String) -> String {
        var result = text
        func replace(_ placeholder: String, _ values: () -> [String]) {
            while let range = result.range(of: placeholder) {
                let options = values()
                result.replaceSubrange(range, with: options[Int.random(in: 0..<options.count, using: &rng)])
            }
        }
        for kind in DeepPools.Kind.allCases {
            replace("{\(kind.rawValue)}") { DeepPools.values(kind, split: split) }
        }
        replace("{name}") { DeepPools.names(split: split) }
        for slot in Slot.allCases {
            replace("{\(slot.rawValue)}") { Pools.values(slot, split: split) }
        }
        replace("{ordinal}") { DeepFrames.ordinals }
        return result
    }

    /// The text as said and as written: `[said|written]` picks a side, and a word marked `~` is
    /// said twice and written once.
    static func alternatives(in text: String) -> (said: String, written: String) {
        var said = ""
        var written = ""
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "["), let bar = rest[open...].firstIndex(of: "|"),
              let close = rest[bar...].firstIndex(of: "]") {
            said += rest[..<open] + rest[rest.index(after: open)..<bar]
            written += rest[..<open] + rest[rest.index(after: bar)..<close]
            rest = rest[rest.index(after: close)...]
        }
        said += rest
        written += rest
        func tidy(_ text: String) -> String {
            text.split(separator: " ").joined(separator: " ")
        }
        let spoken = said.split(separator: " ").map { word in
            word.hasSuffix("~") ? "\(word.dropLast()) \(word.dropLast())" : String(word)
        }.joined(separator: " ")
        return (tidy(spoken), tidy(written.replacingOccurrences(of: "~", with: "")))
    }

    // MARK: - Helpers

    private mutating func twoValues(_ slot: Slot) -> (String, String) {
        let values = slot == .name ? DeepPools.names(split: split) : Pools.values(slot, split: split)
        let old = pick(values)
        return (old, pick(values.filter { $0 != old }))
    }

    private mutating func distinct(_ count: Int, from values: [String]) -> [String] {
        Array(values.shuffled(using: &rng).prefix(count))
    }

    private func sentence(_ text: String) -> String {
        Self.capitalisedFirst(text.trimmingCharacters(in: .whitespaces))
    }

    static func capitalisedFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    /// `text` with its first letter lowercased, unless it starts with "I" or a name.
    static func lowercasedFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        let firstWord = text.prefix { $0 != " " }.trimmingCharacters(in: .punctuationCharacters)
        if firstWord == "I" || firstWord.hasPrefix("I'") || Pools.properNouns.contains(firstWord) {
            return text
        }
        return first.lowercased() + text.dropFirst()
    }

    private mutating func chance(_ share: Double) -> Bool {
        Double.random(in: 0..<1, using: &rng) < share
    }

    private mutating func pick<T>(_ values: [T]) -> T {
        values[Int.random(in: 0..<values.count, using: &rng)]
    }
}
