import Foundation

/// Vocabulary and sentence frames for Deep's synthetic examples (``DeepExampleGenerator``).
///
/// A frame is written as the finished text. `{kind}` placeholders are filled from ``Pools`` or
/// ``DeepPools``; `[said|written]` is a word the recognizer or the speaker got wrong, said one way
/// and written the other (either side may be empty, for a word left out or put in). Test frames
/// and values never appear in training or validation, so the test split measures generalisation.
/// None repeats a sentence of `Training/eval/deep.jsonl`.
enum DeepPools {
    enum Kind: String, CaseIterable {
        case event, doc, surname, grocery, packing, topic, task, step
    }

    static func values(_ kind: Kind, split: DataSplit) -> [String] {
        let pool = all[kind]!
        return split == .test ? pool.test : pool.train
    }

    /// Names for Deep's examples: ``Pools``' names and, in training, many more, short and
    /// uncommon ones among them, so the adapter learns to keep a name it doesn't know as said
    /// rather than "fix" it into one it does ("uma" is not "Una").
    static func names(split: DataSplit) -> [String] {
        let names = Pools.values(.name, split: split)
        return split == .test ? names : names + moreNames
    }

    private static let moreNames = [
        "Ava", "Eli", "Ivy", "Otto", "Ines", "Anya", "Kofi", "Amara", "Nia", "Ravi", "Arjun", "Mei", "Yuki",
        "Kenji", "Lena", "Mateo", "Sofia", "Omar", "Leila", "Tariq", "Zara", "Ingrid", "Siobhan", "Niamh",
        "Aoife", "Ewan", "Rhys", "Aroha", "Nikhil", "Divya", "Kiri", "Hemi", "Ula", "Edda", "Ada", "Ida",
        "Ona", "Ari", "Ezra", "Uri", "Oda", "Pia", "Teo", "Juno", "Rafe", "Cleo", "Nuno", "Ilse", "Bea",
        "Kai", "Lior", "Suki", "Dara", "Tove", "Imre", "Asha", "Enzo", "Femi", "Gita", "Hana",
    ]

    static let all: [Kind: (train: [String], test: [String])] = [
        .event: (
            ["the demo", "the launch", "the inspection", "the workshop", "the board meeting", "the party", "the exam",
             "the move", "the audit", "the offsite", "the product review", "the fundraiser", "the site visit"],
            ["the webinar", "the interview", "the handover", "the recital", "the graduation"]
        ),
        .doc: (
            ["the invoice", "the contract", "the slides", "the budget", "the proposal", "the draft", "the roster",
             "the lease", "the quote", "the design doc", "the forecast"],
            ["the minutes", "the brief", "the timesheet", "the syllabus", "the itinerary"]
        ),
        .surname: (
            ["Silva", "Smith", "Nguyen", "Kowalski", "Brown", "Fernando", "Taylor", "Walsh", "Moreno", "Chen"],
            ["Jayasuriya", "Okafor", "Moreau", "Lindqvist", "Haddad"]
        ),
        .grocery: (
            ["milk", "eggs", "bread", "butter", "rice", "apples", "bananas", "cheese", "yoghurt", "onions", "tomatoes",
             "pasta", "coffee", "tea bags", "olive oil", "spinach", "chicken", "flour"],
            ["lentils", "oat milk", "avocados", "honey", "garlic", "chickpeas"]
        ),
        .packing: (
            ["passports", "sunscreen", "the charger", "a first aid kit", "towels", "hiking boots", "a rain jacket",
             "snacks", "water bottles", "the camera", "swimmers", "the tent", "a torch"],
            ["travel adapters", "insect repellent", "sleeping bags", "a power bank", "sunglasses"]
        ),
        .topic: (
            ["budget review", "hiring plan", "the office move", "customer feedback", "the roadmap", "security updates",
             "quarterly targets", "the holiday roster", "training plans", "vendor contracts"],
            ["the product launch", "support tickets", "the annual survey", "team goals"]
        ),
        .task: (
            ["call the bank", "email {name} about the lease", "book the flights to {city}", "pay the electricity bill",
             "pick up the dry cleaning", "renew the car registration", "send {doc} to {name}", "water the plants",
             "back up the laptop", "order more printer paper", "reply to {name}", "clean out the garage"],
            ["cancel the gym membership", "update the insurance details", "return the library books", "fix the gate"]
        ),
        .step: (
            ["open the app", "go to settings", "turn on backups", "restart the phone", "unplug the router",
             "wait thirty seconds", "plug it back in", "sign in again", "clear the cache", "check the lights",
             "choose a new password", "tap save"],
            ["remove the battery", "hold the power button", "select the network", "enter the code"]
        ),
    ]
}

/// A sentence with a slot a correction can change, as in ``Frames``, but which a correction may
/// also reach from a later sentence: the slot is a name, a place, a day, a month, a time or a
/// number, the kinds Deep's check knows a short correction phrase can be about.
struct CrossFrame {
    let text: String
    let slot: Slot
}

enum DeepFrames {
    // MARK: - Corrections

    static let crossTrain: [CrossFrame] = [
        .init(text: "Please send {doc} to {X} before lunch.", slot: .name),
        .init(text: "{X} is presenting at the all hands.", slot: .name),
        .init(text: "I'm meeting {X} at the station.", slot: .name),
        .init(text: "Can you ask {X} to join the call?", slot: .name),
        .init(text: "{X} will cover my shift.", slot: .name),
        .init(text: "The plumber is coming on {X}.", slot: .weekday),
        .init(text: "We're moving {event} to {X}.", slot: .weekday),
        .init(text: "The bins go out on {X} night.", slot: .weekday),
        .init(text: "Let's catch up on {X} afternoon.", slot: .weekday),
        .init(text: "My sister arrives on {X}.", slot: .weekday),
        .init(text: "{event} is on {X}.", slot: .weekday),
        .init(text: "Our lease renews in {X}.", slot: .month),
        .init(text: "We're going on holiday in {X}.", slot: .month),
        .init(text: "The new hires start in {X}.", slot: .month),
        .init(text: "{event} is at {X}.", slot: .time),
        .init(text: "The bus leaves at {X}.", slot: .time),
        .init(text: "Can you call me back at {X}?", slot: .time),
        .init(text: "The shop closes at {X} today.", slot: .time),
        .init(text: "We need {X} {unit} for the workshop.", slot: .number),
        .init(text: "Order {X} {unit}, please.", slot: .number),
        .init(text: "There were {X} people at the meeting.", slot: .number),
        .init(text: "The table seats {X} people.", slot: .number),
        .init(text: "The parcel is going to {X}.", slot: .city),
        .init(text: "Our team offsite is in {X} this year.", slot: .city),
        .init(text: "I'm flying to {X} on {weekday}.", slot: .city),
    ]

    static let crossTest: [CrossFrame] = [
        .init(text: "Remind {X} about the dentist.", slot: .name),
        .init(text: "The window cleaner comes on {X}.", slot: .weekday),
        .init(text: "The school holidays start in {X}.", slot: .month),
        .init(text: "The ferry departs at {X}.", slot: .time),
        .init(text: "We printed {X} {unit} for the conference.", slot: .number),
        .init(text: "The conference moved to {X}.", slot: .city),
    ]

    /// A sentence to open a dictation with, before the one a correction changes, which a correct
    /// answer keeps as it is. Some leave a verb unsaid ("he didn't"), which nothing may fill in.
    static let leadTrain: [String] = [
        "I tried to call {name} this morning, but they didn't pick up.",
        "I asked {name} to check, but they didn't.",
        "The build finished an hour ago.",
        "{name} sent the draft over last night.",
        "We talked about {component} for a while.",
        "I spoke to {name} about {doc}.",
        "The traffic in {city} was terrible today.",
        "I've booked {room} for the afternoon.",
        "{name} wanted to know the plan.",
        "Just a quick update on {event}.",
        "I checked with {name} earlier.",
        "We finally sorted out {doc}.",
        "{name} said they would help, but they haven't yet.",
        "I haven't heard back from {name}.",
    ]

    static let leadTest: [String] = [
        "I rang {name} twice, but they didn't answer.",
        "The printer jammed again this morning.",
        "{name} hasn't replied to my message.",
    ]

    /// Sentences a speaker is unsure of, whose last words they correct next, for dictations that
    /// run over several sentences with a grammar slip before the correction, as speech does.
    static let doubtTrain: [String] = [
        "I don't think {name} actually [confirm|confirmed] whether {event} is {X}.",
        "I'm not sure {name} [know|knows] that {event} is {X}.",
        "{name} [say|said] {event} is {X}, but I'm not sure.",
        "I don't think we ever [decide|decided] if {event} is {X}.",
    ]

    static let doubtTest: [String] = [
        "I doubt {name} [remember|remembers] that {event} is {X}.",
        "Nobody [have|has] told {name} that {event} is {X}.",
    ]

    /// When something is, and how a garbled correction of it reads: `said` is the correction phrase
    /// as the recognizer wrote it, `written` as the speaker meant it.
    struct Garble {
        let original: String
        let said: String
        let written: String
    }

    static let dayGarblesTrain: [Garble] = [
        .init(original: "tomorrow", said: "the after tomorrow", written: "the day after tomorrow"),
        .init(original: "today", said: "the after tomorrow", written: "the day after tomorrow"),
        .init(original: "next week", said: "the after next", written: "the week after next"),
        .init(original: "next Monday", said: "the Monday after", written: "the Monday after next"),
        .init(original: "next Friday", said: "the Friday after", written: "the Friday after next"),
        .init(original: "next month", said: "the after next", written: "the month after next"),
    ]

    /// Sentences that say when outside the slot a correction changes, whose time must come
    /// through as said: "We're migrating the cache, sorry, the frontend next week." keeps "next
    /// week", and so does a correction of it in a later sentence.
    static let timeKeptTrain: [CrossFrame] = [
        .init(text: "We're migrating {X} next week.", slot: .component),
        .init(text: "{X} is presenting tomorrow.", slot: .name),
        .init(text: "Can you move {X} to the new desk next Monday?", slot: .device),
        .init(text: "We'll paint {X} next month.", slot: .room),
        .init(text: "I'm meeting {X} for lunch tomorrow.", slot: .name),
        .init(text: "The team is replacing {X} next week.", slot: .device),
        .init(text: "We're ordering {X} for the party on Friday.", slot: .food),
        .init(text: "{X} goes live next Tuesday.", slot: .component),
        .init(text: "Let's clean {X} this weekend.", slot: .room),
        .init(text: "I'll call {X} first thing tomorrow morning.", slot: .name),
        .init(text: "We fly to {X} next week.", slot: .city),
        .init(text: "We need {X} chairs for next month.", slot: .number),
    ]

    static let timeKeptTest: [CrossFrame] = [
        .init(text: "We're upgrading {X} next week.", slot: .component),
        .init(text: "{X} is flying in the day after tomorrow.", slot: .name),
        .init(text: "Let's repaint {X} next month.", slot: .room),
        .init(text: "Can you bring {X} to the offsite next Thursday?", slot: .device),
    ]

    static let dayGarblesTest: [Garble] = [
        .init(original: "tomorrow", said: "the after tomorrow", written: "the day after tomorrow"),
        .init(original: "next Thursday", said: "the Thursday after", written: "the Thursday after next"),
    ]

    /// Sentences whose `{X}` says when, for ``dayGarblesTrain``.
    static let whenTrain: [String] = [
        "{event} is {X}.",
        "We're flying out {X}.",
        "The movers are coming {X}.",
        "I'll send {doc} over {X}.",
        "{name} is back in the office {X}.",
        "The package should arrive {X}.",
        "Let's have the retro {X}.",
    ]

    static let whenTest: [String] = [
        "The electrician can come {X}.",
        "My cousin lands {X}.",
    ]

    /// A correction phrase with a stray word the recognizer heard in it, as `(said, written)`:
    /// the preposition or article repeated or put where none was said.
    static let strayTrain: [(frame: String, slot: Slot, stray: [String])] = [
        ("The report goes to {X}.", .name, ["to the to", "the to", "to to"]),
        ("I'll be there by {X}.", .time, ["by the", "by by", "the by"]),
        ("Give the keys to {X}.", .name, ["to the to", "the to"]),
        ("The meeting is with {X}.", .name, ["with the with", "with with"]),
        ("The flight to {X} is full.", .city, ["to the to", "the to"]),
        ("We'll start at {X}.", .time, ["at the at", "at at"]),
        ("Send the invoice to {X}.", .name, ["to the to", "to to"]),
        ("Dinner is on {X}.", .weekday, ["on the on", "on on", "the on"]),
    ]

    static let strayTest: [(frame: String, slot: Slot, stray: [String])] = [
        ("The keys are with {X}.", .name, ["with the with"]),
        ("The parcel goes to {X}.", .city, ["to the to", "the to"]),
    ]

    /// A date said with a day of the month, and a correction that changes its month and drops the
    /// day in the recognizer's version.
    static let datesTrain: [String] = [
        "She starts on the {ordinal} of {X}.",
        "The lease ends on the {ordinal} of {X}.",
        "{event} is on the {ordinal} of {X}.",
        "Our anniversary is the {ordinal} of {X}.",
    ]

    static let datesTest: [String] = [
        "The festival opens on the {ordinal} of {X}.",
    ]

    static let ordinals = ["first", "second", "third", "fourth", "fifth", "sixth", "tenth", "twelfth", "fifteenth", "twentieth"]

    // MARK: - Cues

    /// Cues at the start of a correcting sentence, as a cased transcript writes them. Some are
    /// words that as often start a new point ("No wait", "Actually"), which Deep resolves only
    /// when the phrase after them is the same kind of thing.
    static let sentenceCues = [
        "Sorry,", "Sorry,", "No, sorry,", "No, sorry,", "Sorry, I mean", "I mean,", "No, I mean", "Sorry, no,",
        "No wait,", "Wait, no,", "Actually,", "Actually, no,", "Or rather,", "Make that", "Sorry, I meant",
    ]

    // MARK: - Ordinary uses of cue words

    /// A cue word that starts a new point in a later sentence, or answers a question: every word
    /// stays.
    static let controlTrain: [String] = [
        "Is {event} on {weekday}? No, it's on {weekday}.",
        "Did {name} send {doc}? No, not yet.",
        "Is the meeting at {time}? No, I think it's later.",
        "Are we still going to {city}? No, we cancelled.",
        "I finished {doc}. Sorry, I haven't had time to look at yours yet.",
        "I'll be a few minutes late. Sorry about that.",
        "Sorry, {name}, I missed your call.",
        "The build passed. Actually, it was faster than usual.",
        "We finished early. Actually, that gives us time for {topic}.",
        "I spoke to {name}. Actually, they had some good ideas.",
        "Wait for me at {room}.",
        "No, that's fine, I can do it on {weekday}.",
        "I mean it, the plan for {month} is great.",
        "Sorry to bother you, but is {doc} ready?",
        "We shipped it on {weekday}. Actually, we shipped it a day early.",
        "The trip to {city} was great. No complaints at all.",
        "Can you wait until {time}? I'm stuck in traffic.",
        "I'd rather not move {event} again.",
        "Is {name} coming tonight? No, they're working late.",
        "Sorry for the delay with {doc}.",
    ]

    static let controlTest: [String] = [
        "Is the train at {time}? No, it's been cancelled.",
        "Sorry, I didn't catch that.",
        "I emailed {name}. Actually, I'll call them as well.",
    ]

    // MARK: - Facts and text that is right

    /// Sentences whose names, numbers, dates and negations must come through as said.
    static let factsTrain: [String] = [
        "{name} didn't approve {doc}, and I don't think they will.",
        "We need {number} {unit} by {weekday}, not {number}.",
        "I never said {event} was in {month}.",
        "{name} won't be in {city} until {weekday}.",
        "The invoice for {number} hundred dollars is due on the {ordinal} of {month}.",
        "I can't make it at {time}, but {name} can.",
        "There's no reason to move {event}.",
        "{name} and {name} haven't signed {doc} yet.",
        "It's not the {color} folder, it's the {color} one.",
        "We don't ship to {city} on {weekday}s.",
        "{name} said {number} of the {unit} were broken.",
        "None of us knew {event} was cancelled.",
    ]

    static let factsTest: [String] = [
        "{name} hasn't seen {doc}, and neither have I.",
        "We only have {number} {unit} left, not {number}.",
    ]

    /// Sentences with nothing to fix.
    static let unchangedTrain: [String] = [
        "The build is green, and {name} will deploy it on {weekday}.",
        "Thanks for sending {doc} so quickly.",
        "Let's meet in {room} at {time}.",
        "{name} is looking after {component} this week.",
        "I'll pick up {food} on the way home.",
        "Could you check whether {device} is charged?",
        "We're driving to {city} in {month}.",
        "The kids loved the {color} balloons.",
        "Please let me know if {doc} needs changes.",
        "I think {event} went really well.",
    ]

    static let unchangedTest: [String] = [
        "{name} fixed {component} before lunch.",
        "The {vehicle} to {city} were on time today.",
    ]

    // MARK: - Grammar and misheard words

    /// A grammar slip: `[said|written]`.
    static let grammarTrain: [String] = [
        "{name} [don't|doesn't] know where {doc} is.",
        "We [was|were] planning to leave early.",
        "The printers on level two [is|are] broken again.",
        "I [|am] going to call {name} tonight.",
        "She [|is] coming to {event} on {weekday}.",
        "They [has|have] already sent {doc}.",
        "He [go|goes] to the gym every morning.",
        "Yesterday I [send|sent] {doc} to {name}.",
        "{name} [call|called] me last night.",
        "We [has|have] a lot of work this week.",
        "She [have|has] two meetings on {weekday}.",
        "Did you [finished|finish] {doc}?",
        "I [seen|saw] {name} at the station.",
        "{name} and [me|I] are going to {city}.",
        "It took [a|an] hour to get to {city}.",
        "This is [an|a] useful tool.",
        "The kids [was|were] tired after {event}.",
        "{name} [have|has] never been to {city}.",
        "We [goes|go] to {city} every {month}.",
        "They [was|were] happy with {doc}.",
        "My manager [want|wants] {doc} by {weekday}.",
        "I [has|have] finished {doc}.",
        "{name} [bring|brought] {food} to {event} last week.",
    ]

    static let grammarTest: [String] = [
        "{name} [were|was] late for {event}.",
        "The boxes in {room} [is|are] heavy.",
        "I [|am] waiting for {name}.",
        "She [write|wrote] {doc} yesterday.",
    ]

    /// A word the recognizer heard as another that sounds the same: `[said|written]`.
    static let recognitionTrain: [String] = [
        "Can you [right|write] the summary for {name}?",
        "We need to [except|accept] the offer by {weekday}.",
        "I need to [by|buy] {food} on the way home.",
        "[Their|They're] going to send {doc} tonight.",
        "Put the boxes over [their|there].",
        "[There|Their] office is in {city}.",
        "[Your|You're] welcome to join us on {weekday}.",
        "Is this [you're|your] laptop?",
        "[Its|It's] going to rain in {city} tomorrow.",
        "The app lost [it's|its] settings again.",
        "The new plan is better [then|than] the old one.",
        "Finish {doc} first, [than|then] call {name}.",
        "I don't know [weather|whether] {name} is coming.",
        "Don't [brake|break] the build before {event}.",
        "The [hole|whole] team is going to {city}.",
        "Let's [meat|meet] at the station at {time}.",
        "[Wear|Where] did you leave the keys?",
        "The [knew|new] laptop arrived this morning.",
        "I [red|read] {doc} last night.",
        "Can you [weight|wait] for {name}?",
        "We could [of|have] finished earlier.",
        "It was a [peace|piece] of cake.",
        "The [principle|principal] called a meeting.",
        "I [herd|heard] {name} got the job.",
        "This will [effect|affect] {event}.",
        "Please check the [road map|roadmap] for {month}.",
        "We had [alot|a lot] of rain in {city}.",
        "The [sight|site] visit is on {weekday}.",
        "Take the [rode|road] past the station.",
    ]

    static let recognitionTest: [String] = [
        "Please [right|write] down the address.",
        "The [meat|meet] up is at {time}.",
        "I'm not sure [weather|whether] we should go.",
        "[Your|You're] right about {doc}.",
    ]

    // MARK: - Layout

    static let greetings = ["Hi", "Hi", "Hey", "Hello", "Dear"]
    static let signOffs = ["Cheers", "Thanks", "Thank you", "Kind regards", "Best", "Regards", "Love", "Talk soon", "Best wishes"]

    /// Email bodies, one or more sentences each.
    static let bodiesTrain: [String] = [
        "Thanks for sending {doc}. I'll review it tomorrow and get back to you.",
        "Just landed in {city}. The flight was fine. I'll call you tonight.",
        "Quick update: the migration finished last night and all services are healthy.",
        "Can we move our catch up to {weekday}? Something came up.",
        "I've attached {doc}. Let me know if anything needs changing.",
        "Thank you for your quick reply. The signed contract is attached.",
        "The kids had a great time at {event}. Thanks again for inviting us.",
        "I'm running late today. I should be there by {time}.",
        "Here are the notes from {event}. We agreed to revisit the budget in {month}.",
        "Great to see you last week. Let's do it again soon.",
        "I won't be able to make {event}. Could you send me the recording?",
        "The quote for {number} {unit} is attached. It's valid until the end of {month}.",
    ]

    static let bodiesTest: [String] = [
        "Thanks for the lovely dinner. We should do it again in {month}.",
        "The delivery is booked for {weekday}. Someone needs to be home.",
    ]

    /// How a bulleted list is introduced; the items follow.
    static let listIntrosTrain: [(intro: String, kind: DeepPools.Kind)] = [
        ("I need to buy", .grocery),
        ("We're out of", .grocery),
        ("For the trip we need", .packing),
        ("Don't forget to pack", .packing),
        ("Agenda for {weekday}", .topic),
        ("Topics for the next meeting", .topic),
        ("Things to do today", .task),
        ("This week I need to", .task),
    ]

    static let listIntrosTest: [(intro: String, kind: DeepPools.Kind)] = [
        ("The shopping list is", .grocery),
        ("Things to bring camping", .packing),
        ("On the agenda", .topic),
    ]

    /// How a numbered list of steps is introduced.
    static let stepIntrosTrain = ["The steps are", "To reset the router", "Here's what to do", "To fix it", "Follow these steps"]
    static let stepIntrosTest = ["To set it up"]

    /// Words said to mark each item in turn.
    static let itemMarkers: [[String]] = [
        ["first", "second", "third", "fourth", "fifth"],
        ["first", "then", "then", "then", "then"],
        ["firstly", "secondly", "thirdly", "fourthly", "fifthly"],
        ["number one", "number two", "number three", "number four", "number five"],
    ]
}
