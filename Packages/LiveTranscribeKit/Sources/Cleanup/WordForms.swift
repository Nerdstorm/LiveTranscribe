import Foundation
import Shared

/// What Deep's check (``SelfRepair``) knows about English words: which carry facts no repair may
/// change (numbers, dates and times), which a grammar fix may add, drop or swap, and which
/// spellings are forms of the same word. Every word is normalized with ``EditDistance/normalize(_:)``.
enum WordForms {
    // MARK: - Facts

    /// Words that say when: a repair may not add, drop or change one outside a correction, since
    /// "the day before" is not "the day after".
    static let timeWords: Set<String> = [
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "january", "february", "march", "april", "may", "june", "july", "august", "september", "october",
        "november", "december",
        "today", "tomorrow", "yesterday", "tonight", "noon", "midday", "midnight", "morning", "afternoon",
        "evening", "night", "weekend", "week", "weeks", "month", "months", "year", "years", "fortnight",
        "before", "after", "until", "till", "since", "next", "last", "ago", "early", "earlier", "late", "later",
    ]

    /// Kinds of time a correction may swap one for another ("Tuesday, sorry, Thursday").
    static let dayNames: Set<String> = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
    static let monthNames: Set<String> = [
        "january", "february", "march", "april", "june", "july", "august", "september", "october", "november",
        "december",
    ]
    static let relativeDays: Set<String> = ["today", "tomorrow", "yesterday", "tonight"]
    static let partsOfDay: Set<String> = ["morning", "afternoon", "evening", "night", "noon", "midday", "midnight", "am", "pm", "o'clock"]

    private static let units: [String: Int] = [
        "zero": 0, "oh": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
        "nine": 9,
    ]
    private static let teens: [String: Int] = [
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
        "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    private static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]
    private static let ordinals: [String: Int] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8,
        "ninth": 9, "tenth": 10, "eleventh": 11, "twelfth": 12, "thirteenth": 13, "fourteenth": 14,
        "fifteenth": 15, "sixteenth": 16, "seventeenth": 17, "eighteenth": 18, "nineteenth": 19, "twentieth": 20,
        "thirtieth": 30, "fortieth": 40, "fiftieth": 50, "sixtieth": 60, "seventieth": 70, "eightieth": 80,
        "ninetieth": 90,
    ]
    private static let scales: [String: Int] = ["hundred": 100, "thousand": 1_000, "million": 1_000_000, "billion": 1_000_000_000]
    /// Number words that are not a value on their own ("half", "dozen") and units written as symbols
    /// next to digits ("percent" → "%"), which a repair keeps as said.
    static let quantityWords: Set<String> = [
        "half", "quarter", "dozen", "point", "hundredth", "thousandth", "millionth",
    ]
    static let unitWords: Set<String> = [
        "percent", "degree", "degrees", "dollar", "dollars", "cent", "cents", "buck", "bucks", "pound", "pounds",
        "pence", "euro", "euros", "yen", "rupee", "rupees",
    ]

    /// A number: digits, or a word for one.
    static func isNumber(_ word: String) -> Bool {
        word.contains(where: \.isNumber) || units[word] != nil || teens[word] != nil || tens[word] != nil
            || ordinals[word] != nil || scales[word] != nil || quantityWords.contains(word)
    }

    /// The value of a number written in digits ("25", "21st", "230" from "2:30"), or of a run of
    /// number words ("twenty five", "twenty first", "two thirty"), in one form for both, so the
    /// two can be compared; `nil` when it isn't one number.
    static func value(of words: ArraySlice<String>) -> String? {
        guard let first = words.first else { return nil }
        if words.count == 1, first.contains(where: \.isNumber) {
            return digitsValue(first)
        }
        guard !words.contains(where: { $0.contains(where: \.isNumber) }) else { return nil }
        if let (number, ordinal) = cardinal(words) {
            return ordinal ? "\(number)th" : "\(number)"
        }
        return clockValue(words)
    }

    private static func digitsValue(_ word: String) -> String? {
        let digits = word.prefix(while: \.isNumber)
        guard let number = Int(digits) else { return nil }
        let suffix = word.dropFirst(digits.count)
        if suffix.isEmpty { return "\(number)" }
        return ["st", "nd", "rd", "th"].contains(String(suffix)) ? "\(number)th" : nil
    }

    /// "one hundred twenty five" → 125; "twenty first" → 21, ordinal. Refuses runs that are no one
    /// number, such as "five five".
    private static func cardinal(_ words: ArraySlice<String>) -> (Int, Bool)? {
        enum Last { case none, unit, teen, tens, hundred, scale }
        var total = 0, current = 0
        var last = Last.none
        for (offset, word) in words.enumerated() {
            let isLast = offset == words.count - 1
            if let unit = units[word], word != "oh" {
                guard [.none, .tens, .hundred, .scale].contains(last), !(unit == 0 && words.count > 1) else { return nil }
                current += unit
                last = .unit
            } else if let teen = teens[word] {
                guard [.none, .hundred, .scale].contains(last) else { return nil }
                current += teen
                last = .teen
            } else if let ten = tens[word] {
                guard [.none, .hundred, .scale].contains(last) else { return nil }
                current += ten
                last = .tens
            } else if let ordinal = ordinals[word], isLast {
                let fitsAfterTens = ordinal < 10 && last == .tens
                guard [.none, .hundred, .scale].contains(last) || fitsAfterTens else { return nil }
                return (total + current + ordinal, true)
            } else if word == "hundred" {
                guard [.none, .unit, .teen].contains(last) else { return nil }
                current = max(current, 1) * 100
                last = .hundred
            } else if let scale = scales[word] {
                guard last != .scale else { return nil }
                total += max(current, 1) * scale
                current = 0
                last = .scale
            } else {
                return nil
            }
        }
        return (total + current, false)
    }

    /// "two thirty" → 230 and "nine oh five" → 905, as "2:30" and "9:05" read once their colon is
    /// gone.
    private static func clockValue(_ words: ArraySlice<String>) -> String? {
        let array = Array(words)
        guard array.count >= 2, let hour = units[array[0]] ?? teens[array[0]], (1...12).contains(hour) else { return nil }
        let minutes: Int?
        if array[1] == "oh", array.count == 3, let unit = units[array[2]], unit > 0 {
            minutes = unit
        } else if let (value, ordinal) = cardinal(array[1...]), !ordinal, (10...59).contains(value) {
            minutes = value
        } else {
            minutes = nil
        }
        return minutes.map { "\(hour * 100 + $0)" }
    }

    // MARK: - Grammar

    /// Words a grammar fix may add: articles, auxiliaries, and the prepositions and conjunctions
    /// that hold a clause together ("I going" → "I am going"). No negation, no word of time.
    static let insertable: Set<String> = [
        "a", "an", "the", "to", "of", "that", "it", "there", "and", "as",
        "am", "is", "are", "was", "were", "be", "been", "being", "have", "has", "had", "do", "does", "did",
        "will", "would", "for", "in", "on", "at", "with", "from", "about", "by", "into", "onto",
    ]

    /// Words a grammar fix may drop without changing what was said.
    static let droppable: Set<String> = [
        "a", "an", "the", "to", "of", "that", "it", "there", "and", "so", "just", "really", "very", "then", "well",
        "also", "quite", "pretty", "am", "is", "are", "was", "were", "be", "been", "being", "have", "has", "had",
        "do", "does", "did", "will", "for", "in", "on", "at", "with", "from", "by",
    ]

    /// Words said to mark a list item, which a list's own numbers or bullets replace: "first",
    /// "secondly", "finally", and "number" (as in "number one", whose number goes too).
    static let listMarkers: Set<String> = [
        "first", "firstly", "second", "secondly", "third", "thirdly", "fourth", "fourthly", "fifth", "fifthly",
        "sixth", "seventh", "eighth", "ninth", "tenth", "finally", "lastly", "number",
    ]

    /// A number word with no digits ("five", not "5").
    static func isNumberWord(_ word: String) -> Bool {
        !word.contains(where: \.isNumber) && isNumber(word)
    }

    /// Words a grammar or recognition fix may swap for one another: forms of the same verb or
    /// article, a pronoun's case, and words speech-to-text confuses because they sound alike.
    private static let forms: [[String]] = [
        ["am", "is", "are", "was", "were", "be", "been", "being"],
        ["have", "has", "had", "having"],
        ["do", "does", "did", "doing", "done"],
        ["don't", "doesn't", "didn't"],
        ["isn't", "aren't", "wasn't", "weren't", "ain't"],
        ["hasn't", "haven't", "hadn't"],
        ["won't", "wouldn't"],
        ["can't", "cannot", "couldn't"],
        ["will", "would"], ["can", "could"], ["shall", "should"], ["may", "might"],
        ["a", "an", "the"], ["an", "and"], ["this", "these"], ["that", "those"],
        ["i", "me"], ["he", "him"], ["she", "her"], ["we", "us"], ["they", "them"], ["who", "whom"],
        ["their", "there", "they're"], ["your", "you're"], ["its", "it's"], ["whose", "who's"], ["to", "too"],
        ["then", "than"], ["where", "were", "we're"], ["of", "have"], ["are", "our"],
        ["affect", "effect"], ["lose", "loose"], ["quite", "quiet"], ["advice", "advise"], ["breath", "breathe"],
        // Homophones
        ["right", "write", "rite"], ["hear", "here"], ["meet", "meat"], ["sale", "sail"], ["weight", "wait"],
        ["week", "weak"], ["whole", "hole"], ["new", "knew"], ["flour", "flower"], ["mail", "male"],
        ["pair", "pear"], ["plane", "plain"], ["role", "roll"], ["sea", "see"], ["son", "sun"], ["tail", "tale"],
        ["waist", "waste"], ["wear", "where", "ware"], ["which", "witch"], ["wood", "would"], ["allowed", "aloud"],
        ["bare", "bear"], ["board", "bored"], ["cell", "sell"], ["die", "dye"], ["fair", "fare"], ["great", "grate"],
        ["heal", "heel"], ["hour", "our"], ["made", "maid"], ["passed", "past"], ["peace", "piece"],
        ["principal", "principle"], ["rain", "reign", "rein"], ["road", "rode"], ["some", "sum"], ["stair", "stare"],
        ["steal", "steel"], ["suite", "sweet"], ["threw", "through"], ["way", "weigh"], ["weather", "whether"],
        ["by", "buy", "bye"], ["brake", "break"], ["cite", "site", "sight"], ["desert", "dessert"],
        ["lead", "led"], ["minor", "miner"], ["patience", "patients"], ["presence", "presents"], ["scene", "seen"],
        ["sole", "soul"], ["stationary", "stationery"], ["tide", "tied"], ["vain", "vein"], ["dear", "deer"],
        ["find", "fined"], ["guessed", "guest"], ["hair", "hare"], ["higher", "hire"], ["horse", "hoarse"],
        ["knows", "nose"], ["lessen", "lesson"], ["missed", "mist"], ["pain", "pane"], ["peak", "peek"],
        ["pole", "poll"], ["pray", "prey"], ["real", "reel"], ["root", "route"], ["seam", "seem"],
        ["steak", "stake"], ["story", "storey"], ["team", "teem"], ["whirled", "world"], ["compliment", "complement"],
        ["council", "counsel"], ["capital", "capitol"], ["altar", "alter"], ["bread", "bred"], ["coarse", "course"],
        ["genes", "jeans"], ["groan", "grown"], ["muscle", "mussel"], ["naval", "navel"], ["profit", "prophet"],
        ["sauce", "source"], ["wail", "whale"], ["war", "wore"], ["weave", "we've"],
        ["read", "reed"], ["accept", "except"],
    ]

    /// Irregular verbs, each with its forms: "go", "goes", "went", "gone" are one verb.
    private static let irregularVerbs: [[String]] = [
        ["go", "goes", "went", "gone", "going"], ["get", "gets", "got", "gotten", "getting"],
        ["make", "makes", "made", "making"], ["say", "says", "said", "saying"], ["see", "sees", "saw", "seen", "seeing"],
        ["come", "comes", "came", "coming"], ["take", "takes", "took", "taken", "taking"],
        ["know", "knows", "knew", "known", "knowing"], ["think", "thinks", "thought", "thinking"],
        ["tell", "tells", "told", "telling"], ["give", "gives", "gave", "given", "giving"],
        ["find", "finds", "found", "finding"], ["feel", "feels", "felt", "feeling"], ["leave", "leaves", "left", "leaving"],
        ["bring", "brings", "brought", "bringing"], ["buy", "buys", "bought", "buying"], ["send", "sends", "sent", "sending"],
        ["pay", "pays", "paid", "paying"], ["meet", "meets", "met", "meeting"], ["run", "runs", "ran", "running"],
        ["sit", "sits", "sat", "sitting"], ["speak", "speaks", "spoke", "spoken", "speaking"],
        ["write", "writes", "wrote", "written", "writing"], ["lose", "loses", "lost", "losing"],
        ["hear", "hears", "heard", "hearing"], ["hold", "holds", "held", "holding"], ["keep", "keeps", "kept", "keeping"],
        ["begin", "begins", "began", "begun", "beginning"], ["break", "breaks", "broke", "broken", "breaking"],
        ["choose", "chooses", "chose", "chosen", "choosing"], ["drive", "drives", "drove", "driven", "driving"],
        ["fall", "falls", "fell", "fallen", "falling"], ["forget", "forgets", "forgot", "forgotten", "forgetting"],
        ["grow", "grows", "grew", "grown", "growing"], ["lend", "lends", "lent", "lending"],
        ["ride", "rides", "rode", "ridden", "riding"], ["ring", "rings", "rang", "rung", "ringing"],
        ["sell", "sells", "sold", "selling"], ["show", "shows", "showed", "shown", "showing"],
        ["sing", "sings", "sang", "sung", "singing"], ["sleep", "sleeps", "slept", "sleeping"],
        ["spend", "spends", "spent", "spending"], ["stand", "stands", "stood", "standing"],
        ["teach", "teaches", "taught", "teaching"], ["throw", "throws", "threw", "thrown", "throwing"],
        ["understand", "understands", "understood", "understanding"], ["wake", "wakes", "woke", "woken", "waking"],
        ["wear", "wears", "wore", "worn", "wearing"], ["catch", "catches", "caught", "catching"],
        ["build", "builds", "built", "building"], ["fight", "fights", "fought", "fighting"],
        ["fly", "flies", "flew", "flown", "flying"], ["draw", "draws", "drew", "drawn", "drawing"],
        ["become", "becomes", "became", "becoming"], ["seek", "seeks", "sought", "seeking"],
        ["hang", "hangs", "hung", "hanging"], ["sweep", "sweeps", "swept", "sweeping"], ["deal", "deals", "dealt", "dealing"],
    ]

    private static let related: [String: Set<String>] = {
        var related: [String: Set<String>] = [:]
        for group in forms + irregularVerbs {
            for word in group {
                related[word, default: []].formUnion(group.filter { $0 != word })
            }
        }
        return related
    }()

    /// Whether `lhs` and `rhs` are forms of one word ("check", "checked"; "go", "went"; "is",
    /// "are"), or words speech-to-text confuses ("their", "there").
    static func areForms(_ lhs: String, _ rhs: String) -> Bool {
        if related[lhs]?.contains(rhs) == true { return true }
        let shorter = lhs.count <= rhs.count ? lhs : rhs
        let longer = lhs.count <= rhs.count ? rhs : lhs
        return !stems(of: shorter).isDisjoint(with: stems(of: longer))
    }

    /// `word` and what it is with a regular ending taken off ("checked" → "check", "tries" → "try",
    /// "making" → "make", "stopped" → "stop"). Stems shorter than three letters are left out, so
    /// "bed" is not "be".
    private static func stems(of word: String) -> Set<String> {
        var stems: Set<String> = [word]
        func add(_ stem: some StringProtocol) {
            if stem.count >= 3 { stems.insert(String(stem)) }
        }
        for suffix in ["ing", "ed", "es", "s"] where word.hasSuffix(suffix) && word.count > suffix.count + 2 {
            let stem = word.dropLast(suffix.count)
            add(stem)
            if suffix == "ing" || suffix == "ed" {
                add(stem + "e")
                if let last = stem.last, stem.dropLast().last == last { add(stem.dropLast()) }
            }
        }
        if word.hasSuffix("ies") || word.hasSuffix("ied") { add(word.dropLast(3) + "y") }
        return stems
    }

    // MARK: - Contractions

    /// The two words `word` contracts, where it is a contraction: "don't" → ["do", "not"],
    /// "it's" → ["it", "is"] or ["it", "has"], "won't" → ["will", "not"].
    static func expansions(of word: String) -> [[String]] {
        switch word {
        case "won't": return [["will", "not"]]
        case "can't", "cannot": return [["can", "not"]]
        case "shan't": return [["shall", "not"]]
        case "let's": return [["let", "us"]]
        case "ain't": return [["am", "not"], ["is", "not"], ["are", "not"]]
        default: break
        }
        let endings: [(String, [String])] = [
            ("n't", ["not"]), ("'re", ["are"]), ("'ve", ["have"]), ("'ll", ["will", "shall"]),
            ("'d", ["would", "had"]), ("'m", ["am"]), ("'s", ["is", "has"]),
        ]
        for (ending, meanings) in endings where word.hasSuffix(ending) && word.count > ending.count {
            let stem = String(word.dropLast(ending.count))
            return meanings.map { [stem, $0] }
        }
        return []
    }
}
