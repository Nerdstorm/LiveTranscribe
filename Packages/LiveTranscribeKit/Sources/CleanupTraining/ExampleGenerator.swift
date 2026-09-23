import Foundation
import Shared

/// Which part of the data an example belongs to. Test examples use sentence frames and slot
/// values that never appear in training or validation, so evaluation measures generalisation.
public enum DataSplit: String, Sendable, CaseIterable {
    case train
    case valid
    case test
}

/// Builds synthetic examples from sentence frames and word pools, reproducibly from a seed.
///
/// Each frame is written as the finished transcript line. A correction frame has one `{X}` slot:
/// the raw text says "A, cue, B" there and the target says "B". Other `{kind}` placeholders are
/// filled at random and left alone. Half the raw texts are lowercase without punctuation, like a
/// streaming recogniser; the other half are cased and punctuated, like Parakeet's final output.
public struct ExampleGenerator: Sendable {
    public struct Counts: Sendable, Equatable {
        public var correction: Int
        public var scratch: Int
        public var control: Int
        public var cleanup: Int
        public var boundary: Int

        public var total: Int { correction + scratch + control + cleanup + boundary }
    }

    public static func counts(for split: DataSplit) -> Counts {
        switch split {
        case .train: Counts(correction: 1_400, scratch: 120, control: 700, cleanup: 600, boundary: 120)
        case .valid: Counts(correction: 140, scratch: 12, control: 70, cleanup: 60, boundary: 12)
        case .test: Counts(correction: 200, scratch: 20, control: 100, cleanup: 80, boundary: 20)
        }
    }

    /// Share of examples that carry earlier transcript lines as context.
    static let contextShare = 0.3

    public let split: DataSplit
    private var rng: SeededGenerator

    public init(split: DataSplit, seed: UInt64) {
        self.split = split
        self.rng = SeededGenerator(seed: seed)
    }

    /// Unique examples for the split. Raw texts in `excluding`, compared ignoring casing and
    /// punctuation, are skipped, which keeps the splits apart: short boundary texts such as
    /// "I mean, Sunday" can otherwise come up in more than one.
    public mutating func generate(counts: Counts? = nil, excluding: Set<String> = []) -> [TrainingExample] {
        let counts = counts ?? Self.counts(for: split)
        let excluded = Set(excluding.map(EditDistance.normalize))
        var seen = Set<String>()
        var examples: [TrainingExample] = []
        func add(_ count: Int, _ make: (inout ExampleGenerator) -> TrainingExample) {
            var added = 0
            var attempts = 0
            while added < count && attempts < count * 50 {
                attempts += 1
                var example = make(&self)
                guard !excluded.contains(EditDistance.normalize(example.raw)), seen.insert(example.raw).inserted else { continue }
                if example.category != .boundary, example.context.isEmpty, Double.random(in: 0..<1, using: &rng) < Self.contextShare {
                    example.context = contextLines()
                }
                examples.append(example)
                added += 1
            }
        }
        add(counts.correction) { $0.correction() }
        add(counts.scratch) { $0.scratchThat() }
        add(counts.control) { $0.control() }
        add(counts.cleanup) { $0.cleanup() }
        add(counts.boundary) { $0.boundary() }
        examples.shuffle(using: &rng)
        return examples
    }

    // MARK: - Categories

    mutating func correction() -> TrainingExample {
        let frame = pick(split == .test ? Frames.correctionTest : Frames.correctionTrain)
        let values = Pools.values(frame.slot, split: split)
        let retracted = pick(values)
        let correction = pick(values.filter { $0 != retracted })
        let cue = pick(Cues.correction)
        let filled = fillPlaceholders(frame.text)
        let target = sentence(filled.replacingOccurrences(of: "{X}", with: correction))
        let spoken = sentence(filled.replacingOccurrences(of: "{X}", with: "\(retracted), \(cue), \(correction)"))
        return TrainingExample(category: .correction, raw: rawStyle(spoken), target: target, source: "generated")
    }

    mutating func scratchThat() -> TrainingExample {
        let pair = pick(split == .test ? Frames.scratchTest : Frames.scratchTrain)
        let target = sentence(fillPlaceholders(pair.kept))
        let spoken = sentence("\(fillPlaceholders(pair.dropped)), scratch that, \(lowercasedFirst(target))")
        return TrainingExample(category: .correction, raw: rawStyle(spoken), target: target, source: "generated")
    }

    mutating func control() -> TrainingExample {
        let text = sentence(fillPlaceholders(pick(split == .test ? Frames.controlTest : Frames.controlTrain)))
        return TrainingExample(category: .control, raw: rawStyle(text), target: text, source: "generated")
    }

    mutating func cleanup() -> TrainingExample {
        let frame = fillPlaceholders(pick(split == .test ? Frames.cleanupTest : Frames.cleanupTrain))
        // A word marked "~" is spoken twice and written once.
        let target = sentence(frame.replacingOccurrences(of: "~", with: ""))
        let spoken = sentence(frame.split(separator: " ").map { word in
            word.hasSuffix("~") ? "\(word.dropLast()) \(word.dropLast())" : String(word)
        }.joined(separator: " "))
        return TrainingExample(category: .cleanup, raw: rawStyle(spoken), target: target, source: "generated")
    }

    /// The cue opens the segment and corrects the previous one, which the app cannot edit.
    mutating func boundary() -> TrainingExample {
        let frame = pick(split == .test ? Frames.correctionTest : Frames.correctionTrain)
        let values = Pools.values(frame.slot, split: split)
        let retracted = pick(values)
        let correction = pick(values.filter { $0 != retracted })
        let previous = sentence(fillPlaceholders(frame.text).replacingOccurrences(of: "{X}", with: retracted))
        let text = sentence("\(pick(Cues.boundary)), \(correction)")
        return TrainingExample(category: .boundary, context: [previous], raw: rawStyle(text), target: text, source: "generated")
    }

    // MARK: - Text

    private mutating func contextLines() -> [String] {
        let frames = split == .test ? Frames.cleanupTest + Frames.controlTest : Frames.cleanupTrain + Frames.controlTrain
        return (0..<Int.random(in: 1...2, using: &rng)).map { _ in
            sentence(fillPlaceholders(pick(frames)).replacingOccurrences(of: "~", with: ""))
        }
    }

    /// Replaces every `{kind}` placeholder except `{X}` with a value from its pool.
    private mutating func fillPlaceholders(_ text: String) -> String {
        var result = text
        for slot in Slot.allCases {
            let placeholder = "{\(slot.rawValue)}"
            while let range = result.range(of: placeholder) {
                result.replaceSubrange(range, with: pick(Pools.values(slot, split: split)))
            }
        }
        return result
    }

    /// Half lowercase without punctuation, half as written.
    private mutating func rawStyle(_ text: String) -> String {
        Bool.random(using: &rng) ? EditDistance.normalize(text) : text
    }

    private func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return trimmed }
        return first.uppercased() + trimmed.dropFirst()
    }

    private func lowercasedFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        // Keep "I", "I'm" and proper nouns as they are.
        let firstWord = text.prefix { $0 != " " }
        if firstWord == "I" || firstWord.hasPrefix("I'") || Pools.properNouns.contains(String(firstWord)) {
            return text
        }
        return first.lowercased() + text.dropFirst()
    }

    private mutating func pick<T>(_ values: [T]) -> T {
        values[Int.random(in: 0..<values.count, using: &rng)]
    }
}

// MARK: - Vocabulary

enum Slot: String, CaseIterable {
    case name, weekday, month, time, number, unit, city, vehicle, color, room, component, device, food
}

enum Cues {
    /// As written between the retracted words and the correction in a cased transcript.
    static let correction = [
        "sorry", "sorry", "sorry", "I mean", "I mean", "no wait", "no wait", "or rather",
        "actually", "actually", "make that", "actually, make that", "no, sorry", "sorry, I mean",
        "wait, no", "I meant", "no",
    ]
    static let boundary = ["Sorry", "I mean", "No wait", "Sorry, I mean", "Actually"]
}

enum Pools {
    static func values(_ slot: Slot, split: DataSplit) -> [String] {
        let pool = all[slot]!
        return split == .test ? pool.test : pool.train
    }

    static let properNouns: Set<String> = Set(
        [Slot.name, .weekday, .month, .city].flatMap { all[$0]!.train + all[$0]!.test }
    )

    private static let weekdays = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
    private static let months = [
        "January", "February", "March", "April", "May", "June", "July", "August", "September",
        "October", "November", "December",
    ]

    /// Training and validation values, and disjoint test values where the vocabulary allows.
    static let all: [Slot: (train: [String], test: [String])] = [
        .name: (
            ["Alice", "Ben", "Chloe", "Daniel", "Emma", "Felix", "Grace", "Hannah", "Isaac", "Jack",
             "Karen", "Liam", "Maya", "Noah", "Olivia", "Peter", "Rachel", "Sam", "Tara", "Oscar"],
            ["Uma", "Victor", "Wendy", "Xavier", "Yasmin", "Zoe", "Adrian", "Bianca", "Colin", "Delia"]
        ),
        .weekday: (weekdays, weekdays),
        .month: (months, months),
        .time: (
            ["two pm", "three pm", "four pm", "ten am", "nine am", "eleven am", "noon",
             "half past two", "quarter past nine", "ten thirty"],
            ["five pm", "six pm", "eight am", "half past four", "quarter to three", "seven thirty"]
        ),
        .number: (
            ["two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "twelve",
             "fifteen", "twenty", "thirty", "fifty"],
            ["eleven", "fourteen", "sixteen", "eighteen", "twenty five", "forty", "sixty"]
        ),
        .unit: (
            ["servers", "people", "tickets", "chairs", "boxes", "laptops"],
            ["rooms", "cables", "licences", "tables"]
        ),
        .city: (
            ["Paris", "Berlin", "Tokyo", "Sydney", "Chicago", "Boston", "Denver", "Dublin", "Madrid",
             "Oslo", "Rome", "Seattle"],
            ["Lisbon", "Vienna", "Seoul", "Perth", "Austin", "Toronto", "Prague"]
        ),
        .vehicle: (
            ["cars", "buses", "trucks", "trains", "vans", "bikes"],
            ["planes", "boats", "scooters", "ferries"]
        ),
        .color: (
            ["red", "blue", "green", "black", "white", "grey"],
            ["yellow", "orange", "purple", "navy"]
        ),
        .room: (
            ["the kitchen", "the office", "the lobby", "the garage", "the basement", "the attic", "the hallway"],
            ["the patio", "the studio", "the loft", "the cellar"]
        ),
        .component: (
            ["the login service", "the auth service", "the billing service", "the database", "the cache",
             "the search index", "the payment API", "the frontend"],
            ["the message queue", "the load balancer", "the email service", "the scheduler"]
        ),
        .device: (
            ["the laptop", "the phone", "the tablet", "the monitor", "the printer", "the router"],
            ["the projector", "the camera", "the speaker", "the scanner"]
        ),
        .food: (
            ["pizza", "sushi", "pasta", "tacos", "curry", "salad"],
            ["burgers", "noodles", "dumplings", "soup"]
        ),
    ]
}

struct CorrectionFrame {
    let text: String
    let slot: Slot
}

/// Sentence frames, written as the finished line. None repeats the wording of the prompt probe's
/// cases, which stay a separate check.
enum Frames {
    static let correctionTrain: [CorrectionFrame] = [
        .init(text: "Please forward the contract to {X} today.", slot: .name),
        .init(text: "{X} will lead the design review.", slot: .name),
        .init(text: "Can you ask {X} whether the demo is ready?", slot: .name),
        .init(text: "I had lunch with {X} yesterday.", slot: .name),
        .init(text: "{X} is flying out on {weekday}.", slot: .name),
        .init(text: "We should hire {X} for the role.", slot: .name),
        .init(text: "The deadline moved to {X}.", slot: .weekday),
        .init(text: "We're flying out on {X} morning.", slot: .weekday),
        .init(text: "The plumber is coming on {X}.", slot: .weekday),
        .init(text: "Can we do the review on {X}?", slot: .weekday),
        .init(text: "My shift starts on {X}.", slot: .weekday),
        .init(text: "We moved the release to {X}.", slot: .month),
        .init(text: "The conference is in {X} this year.", slot: .month),
        .init(text: "The rent goes up in {X}.", slot: .month),
        .init(text: "School starts again in {X}.", slot: .month),
        .init(text: "The call starts at {X}.", slot: .time),
        .init(text: "Pick me up at {X}.", slot: .time),
        .init(text: "The train to {city} leaves at {X}.", slot: .time),
        .init(text: "Dinner is at {X} tonight.", slot: .time),
        .init(text: "The store opens at {X} on {weekday}.", slot: .time),
        .init(text: "We ordered {X} {unit} for the event.", slot: .number),
        .init(text: "I need {X} {unit} by tomorrow.", slot: .number),
        .init(text: "There are {X} {unit} left in stock.", slot: .number),
        .init(text: "Add {X} {unit} to the order.", slot: .number),
        .init(text: "The flight to {X} is delayed.", slot: .city),
        .init(text: "She grew up in {X}.", slot: .city),
        .init(text: "Our new office is in {X}.", slot: .city),
        .init(text: "We're driving to {X} this weekend.", slot: .city),
        .init(text: "The city is buying more electric {X}.", slot: .vehicle),
        .init(text: "We compared the running costs of {X} this year.", slot: .vehicle),
        .init(text: "The report covers emissions from {X}.", slot: .vehicle),
        .init(text: "Paint the fence {X}.", slot: .color),
        .init(text: "I'd like the {X} one, please.", slot: .color),
        .init(text: "The logo should be {X}.", slot: .color),
        .init(text: "We picked {X} for the walls.", slot: .color),
        .init(text: "Put the boxes in {X}.", slot: .room),
        .init(text: "The meeting moved to {X}.", slot: .room),
        .init(text: "I left my charger in {X}.", slot: .room),
        .init(text: "The leak is in {X}.", slot: .room),
        .init(text: "The bug is in {X}.", slot: .component),
        .init(text: "We need to restart {X}.", slot: .component),
        .init(text: "{X} is throwing errors again.", slot: .component),
        .init(text: "Let's add caching to {X}.", slot: .component),
        .init(text: "The alert came from {X}.", slot: .component),
        .init(text: "Can you bring {X} to the meeting?", slot: .device),
        .init(text: "{X} won't connect to the wifi.", slot: .device),
        .init(text: "I ordered a new cable for {X}.", slot: .device),
        .init(text: "Reset {X} before you leave.", slot: .device),
        .init(text: "Let's order {X} tonight.", slot: .food),
        .init(text: "I'm making {X} for dinner.", slot: .food),
        .init(text: "The kids want {X} again.", slot: .food),
    ]

    static let correctionTest: [CorrectionFrame] = [
        .init(text: "{X} left the keys at reception.", slot: .name),
        .init(text: "Tell {X} the train is delayed.", slot: .name),
        .init(text: "The store reopens on {X}.", slot: .weekday),
        .init(text: "Our next sprint ends on {X}.", slot: .weekday),
        .init(text: "The lease ends in {X}.", slot: .month),
        .init(text: "The match kicks off at {X}.", slot: .time),
        .init(text: "My dentist appointment is at {X}.", slot: .time),
        .init(text: "We'll need {X} {unit} next week.", slot: .number),
        .init(text: "They shipped {X} {unit} this morning.", slot: .number),
        .init(text: "The tour ends in {X}.", slot: .city),
        .init(text: "My cousin moved to {X}.", slot: .city),
        .init(text: "Insurance for {X} went up again.", slot: .vehicle),
        .init(text: "The new jerseys are {X}.", slot: .color),
        .init(text: "The cat is hiding in {X}.", slot: .room),
        .init(text: "{X} ran out of memory.", slot: .component),
        .init(text: "We're migrating {X} next week.", slot: .component),
        .init(text: "{X} needs a firmware update.", slot: .device),
        .init(text: "We had {X} at the market.", slot: .food),
    ]

    /// A short clause the speaker takes back with "scratch that", and the one they keep.
    static let scratchTrain: [(dropped: String, kept: String)] = [
        ("Let's order pizza", "Let's cook at home tonight."),
        ("We could deploy tonight", "Let's deploy tomorrow morning."),
        ("I'll call {name} now", "I'll email {name} instead."),
        ("Move it to {weekday}", "Keep it on {weekday}."),
        ("Book the early flight", "Book the afternoon one."),
        ("We should cancel the trip", "Let's just postpone it."),
        ("Take the highway", "Take the coast road."),
        ("Put it in {room}", "Leave it by the door."),
        ("I'll finish it today", "I'll finish it on {weekday}."),
        ("Invite the whole team", "Just invite {name} and {name}."),
    ]

    static let scratchTest: [(dropped: String, kept: String)] = [
        ("Buy the blue sofa", "Buy the grey one."),
        ("Start with the budget", "Start with the timeline."),
        ("Ship it to {city}", "Hold it until {month}."),
    ]

    /// A correction cue in its ordinary meaning.
    static let controlTrain: [String] = [
        "Sorry I'm late, the traffic near {city} was awful.",
        "I'm really sorry about the mix-up with {name}.",
        "Sorry to interrupt, but {name} is on the phone.",
        "Sorry, can you repeat the last part?",
        "We said sorry to {name} for the delay.",
        "I mean it this time, we ship on {weekday}.",
        "I mean, the plan for {month} looks fine to me.",
        "You know what I mean about {component}?",
        "That's not what I mean.",
        "No problem, I'll send it to {name}.",
        "There's no way we finish by {weekday}.",
        "No one told {name} about the change.",
        "No, I don't think {component} is the issue.",
        "We have no {unit} left.",
        "Wait for {name} before you start.",
        "I can't wait to visit {city}.",
        "We can wait until {weekday}.",
        "Please wait outside {room}.",
        "I'd rather take the train to {city}.",
        "We should fix {component} rather than rewrite it.",
        "It's rather cold in {room}.",
        "It's actually faster to drive to {city}.",
        "Did you actually talk to {name}?",
        "Actually, that works for me.",
        "The new tablet is actually quite good.",
        "Can you make that call to {name} today?",
        "Let's make that change in {component}.",
        "We sent a correction to {name} this morning.",
        "The correction to the invoice is done.",
        "I'm sorry, but {room} is booked all {weekday}.",
        "Sorry, {name}, the meeting moved to {time}.",
        "What I mean is {component} needs more tests.",
        "Sorry, is the {color} folder yours?",
        "No, {name} already booked the {vehicle}.",
        "There's no {food} left in {room}.",
        "Wait until {time} before you call {name}.",
        "{name} said the wait in {city} was two hours.",
        "Would you rather have {food} tonight?",
        "{name} is actually from {city}.",
        "Make that booking for {number} {unit}, please.",
        "The correction for {month} is in the report.",
    ]

    static let controlTest: [String] = [
        "Sorry for the late reply, {name}.",
        "I'm sorry the delivery to {city} was late.",
        "I mean, honestly, {name} did a great job.",
        "No worries, {name} can take it.",
        "There's no parking near the station in {city}.",
        "Wait here while I get {device}.",
        "I would rather meet on {weekday}.",
        "We actually finished early on {weekday}.",
        "We need to make that deadline.",
        "The paper needs a small correction.",
    ]

    /// No correction cues. A word marked "~" is spoken twice.
    static let cleanupTrain: [String] = [
        "I think we should probably move the review to {weekday}.",
        "Um, so the plan is to restart {component} on {weekday}.",
        "Yeah, I can pick up {name} from the station at {time}.",
        "It's kind of hard to say, but maybe {number} people will come.",
        "So like, the~ main problem is {component}.",
        "We'll probably be in {city} by {month}.",
        "Uh, can you check if {device} is charged?",
        "Honestly, I'm not sure {name} got the email.",
        "The flight lands at {time}, I think.",
        "You know, the {vehicle} were late again.",
        "Let's grab {food} after the meeting.",
        "I guess we could paint it {color}.",
        "Maybe we should ask {name} first.",
        "The~ report is due on {weekday}.",
        "So basically {component} handles all the requests.",
        "Um, I'll~ send the slides to {name} tonight.",
        "It was sort of a long day, to be honest.",
        "We might need {number} {unit} for the launch.",
        "Can you remind me to call {name} at {time}?",
        "The weather in {city} was kind of terrible.",
    ]

    static let cleanupTest: [String] = [
        "Um, I'll call {name} when I land in {city}.",
        "I think {device} is still in {room}.",
        "We could kind of try {food} tonight.",
        "The~ scheduler runs every hour, I believe.",
        "Honestly, the {vehicle} in {city} are pretty reliable.",
    ]
}
