import Foundation

/// Writes spoken numbers in digits, deterministically, once cleanup and the list layout are done.
/// Speech-to-text writes numbers as words, and the model resolves a correction in words ("fifty
/// thousand, I mean sixty thousand" → "sixty thousand"), so the digits come after it: "60,000".
///
/// Always in digits, whatever the number:
/// - digits said one by one, three or more, "oh" as zero: "zero four four six" → "0446";
/// - decimals and versions: "two point five" → "2.5", "version two point four point one" →
///   "version 2.4.1", and any number after "version" ("version 2");
/// - percentages: "twenty five percent" → "25%";
/// - dollars and cents: "one hundred and twenty five dollars" → "$125", "five dollars and fifty
///   cents" → "$5.50", "two dollars fifty" → "$2.50", "fifty cents" → "50 cents";
/// - times, after "at", "by", "from", "until", "till", "around", "before" or "after", or before
///   "am" or "pm": "at nine fifteen" → "at 9:15", "seven thirty pm" → "7:30 pm";
/// - years said in halves, 1900 to 2099: "in twenty twenty six" → "in 2026";
/// - decades and centuries said with their first two digits: "the nineteen nineties" → "the
///   1990s", "the eighteen hundreds" → "the 1800s".
///
/// Other numbers are counts: one to nine stay words, 10 and up become digits ("twenty one
/// chairs" → "21 chairs"). Numbers of five digits or more take commas (50,000) and four-digit
/// ones don't, so a count reads like a year (1500, 2026); whole millions and billions keep the
/// word ("5 million"). A number that starts a sentence is written the same way. "A hundred" or "a
/// thousand" with more number words after it is a count too: "a hundred and fifty" → "150".
///
/// Number words are read in any case ("Zero Four Four Six") and hyphenated ("twenty-one",
/// "twenty-five-year-old" → "25-year-old"). Punctuation or a line break ends a number, except a
/// comma after "thousand", "million" or "billion" before more hundreds ("two thousand, five
/// hundred" → "2500"). A number that runs into a word such as "twelve-year-olds" is a count,
/// never a year or a time: "twenty twelve-year-olds" → "20 12-year-olds".
///
/// In a range, the scale word and the unit after the last number carry back to the first:
/// "twenty to thirty thousand" → "20,000 to 30,000", "five to ten percent" → "5% to 10%", "ten
/// to twenty million dollars" → "$10 million to $20 million".
///
/// These stay as said:
/// - "one" and every count below ten, so list markers that were not laid out stay words ("One, go
///   to shops, two, …") and lists that were start with digits already ("1. ");
/// - number words that make no one number: "nine eleven", "twenty four seven", "nine fifteen"
///   with no "at" or "pm";
/// - a number before an ordinal ("twenty first"), "o'clock" or "and a half", in a clock phrase
///   ("half past ten", "twenty to eleven"), and "a hundred" or "a thousand" alone, except before
///   "dollars" or "percent";
/// - a range or series with a count below ten: "five to ten", "nine or ten", "eight, nine, ten"
///   (but "ten to fifteen" → "10 to 15");
/// - idioms (``idioms``) and the phrases the rule is told to keep, such as vocabulary terms.
public struct NumberStyle: Sendable {
    /// Idioms whose numbers stay words.
    public static let idioms = [
        "a thousand and one", "forty winks", "hindsight is twenty twenty", "twenty twenty hindsight",
        "twenty twenty vision",
    ]

    /// Words before a time: "at nine fifteen".
    private static let timeCues: Set<String> = ["at", "by", "from", "until", "till", "around", "before", "after"]
    /// Words between two times: "from nine thirty to ten fifteen".
    private static let timeLinks: Set<String> = ["to", "and", "or", "until", "till"]
    private static let meridiems: Set<String> = ["am", "pm", "a.m", "p.m"]
    /// Words that make two numbers a range or a series, besides a comma.
    private static let rangeLinks: Set<String> = ["to", "or", "and"]
    /// Minutes said before "past" or "to" in a clock phrase: "twenty past ten".
    private static let clockMinutes: Set<Int> = [5, 10, 20, 25]
    /// The decades said after a century, "the nineteen nineties", and their tens.
    private static let decades: [String: Int] = [
        "twenties": 20, "thirties": 30, "forties": 40, "fifties": 50, "sixties": 60, "seventies": 70,
        "eighties": 80, "nineties": 90,
    ]
    private static let ordinals: Set<String> = [
        "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth", "eleventh",
        "twelfth", "thirteenth", "fourteenth", "fifteenth", "sixteenth", "seventeenth", "eighteenth", "nineteenth",
        "twentieth", "thirtieth", "fortieth", "fiftieth", "sixtieth", "seventieth", "eightieth", "ninetieth",
        "hundredth", "thousandth", "millionth", "billionth",
    ]

    /// The words of each phrase that keeps its numbers as written, lowercased.
    private let keptPhrases: [[String]]

    /// - Parameter phrases: Phrases whose numbers stay as written, such as vocabulary terms
    ///   ("Studio Fifty-Four"), matched in any case. The ``idioms`` are kept too.
    public init(keeping phrases: [String] = []) {
        keptPhrases = (Self.idioms + phrases)
            .map { Self.words(in: $0).map(\.text) }
            .filter { $0.contains(where: NumberWords.isNumberWord) }
    }

    /// `text` with its spoken numbers written as the type describes.
    public func written(_ text: String) -> String {
        let words = Self.words(in: text)
        guard words.contains(where: { NumberWords.isNumberWord($0.text) }) else { return text }
        let kept = keptWords(in: words)

        var readings: [Reading] = []
        var readUpTo = 0
        for run in Self.runs(in: words, kept: kept) where run.lowerBound >= readUpTo {
            Self.read(run, in: words, into: &readings)
            readUpTo = readings.last?.words.upperBound ?? readUpTo
        }
        Self.keepClockPhrases(&readings, in: words)
        Self.carryScalesBack(&readings, in: words)
        Self.carryUnitsBack(&readings, in: words)
        Self.keepRangesWithSmallCounts(&readings, in: words)

        var result = ""
        var position = text.startIndex
        for reading in readings {
            guard let replacement = reading.text else { continue }
            let start = words[reading.words.lowerBound].range.lowerBound
            result += text[position..<start] + replacement
            position = words[reading.words.upperBound - 1].range.upperBound
        }
        return result + text[position...]
    }

    /// Indices of the words in a kept phrase or idiom.
    private func keptWords(in words: [Word]) -> Set<Int> {
        var kept = Set<Int>()
        for phrase in keptPhrases where phrase.count <= words.count {
            for start in 0...(words.count - phrase.count)
            where phrase.indices.allSatisfy({ words[start + $0].text == phrase[$0] }) {
                kept.formUnion(start..<start + phrase.count)
            }
        }
        return kept
    }

    // MARK: - Runs

    /// Runs of number words that may make one number. A run starts a token and goes on over
    /// spaces and hyphens; "and" after "hundred" or a scale word, "point" between numbers, and a
    /// comma after a scale word may join it to more number words. A token that mixes number
    /// words with others ends a run.
    private static func runs(in words: [Word], kept: Set<Int>) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        var index = 0
        while index < words.count {
            guard words[index].startsToken, !kept.contains(index), NumberWords.isNumberWord(words[index].text) else {
                index += 1
                continue
            }
            var end = index + 1
            while let next = continuation(after: end - 1, in: words, kept: kept) {
                end = next
            }
            runs.append(index..<end)
            index = end
        }
        return runs
    }

    /// The end of the run when it goes on past word `index`: one past the next word, or past
    /// the "and" or "point" and the word after it; `nil` when the run ends at `index`.
    private static func continuation(after index: Int, in words: [Word], kept: Set<Int>) -> Int? {
        let next = index + 1
        guard next < words.count, !kept.contains(next) else { return nil }
        let previous = words[index]
        let word = words[next]
        if previous.inMixedToken, word.startsToken { return nil }
        if !previous.runsOn {
            let joinsAcrossComma = previous.trailing == "," && !previous.separatedFromNext
                && NumberWords.scales[previous.text] != nil
                && NumberWords.isNumberWord(word.text) && word.text != NumberWords.oh
            return joinsAcrossComma ? next + 1 : nil
        }
        if NumberWords.isNumberWord(word.text) { return next + 1 }
        let joiner = (word.text == NumberWords.and && NumberWords.isMultiplier(previous.text))
            || (word.text == NumberWords.point && NumberWords.isNumberWord(previous.text))
        guard joiner, word.runsOn, next + 1 < words.count, !kept.contains(next + 1) else { return nil }
        let after = words[next + 1].text
        guard NumberWords.isNumberWord(after), !NumberWords.isMultiplier(after),
              after != NumberWords.oh || word.text == NumberWords.point
        else { return nil }
        return next + 2
    }

    // MARK: - Readings

    private enum Unit {
        case percent, dollars, cents

        /// `digits` with the unit's sign: "25%", "$125", or "50" before "cents".
        func written(_ digits: String) -> String {
            switch self {
            case .percent: digits + "%"
            case .dollars: "$" + digits
            case .cents: digits
            }
        }
    }

    /// What a run says, and the words it replaces.
    private struct Reading {
        enum Kind {
            /// A number said without a unit: `value` for a whole number, `nil` for a decimal.
            case plain(digits: String, value: Int?)
            case unit(Unit)
            case time
            /// Digits said one by one, a year, a version, or words that stay as said.
            case other
        }

        /// The run, with the "a" before or the unit words after it that it took.
        var words: Range<Int>
        /// What replaces the words, or `nil` to leave them as said.
        var text: String?
        var kind: Kind
    }

    /// Appends what `run` says to `readings`. A run that makes no one number is split where a
    /// comma, "and" or a mixed token joined it, and its parts are read on their own.
    private static func read(_ run: Range<Int>, in words: [Word], into readings: inout [Reading]) {
        if let reading = reading(of: run, in: words, after: readings.last) {
            readings.append(reading)
            return
        }
        guard let (left, right) = split(run, in: words) else {
            readings.append(Reading(words: run, text: nil, kind: .other))
            return
        }
        read(left, in: words, into: &readings)
        read(right, in: words, into: &readings)
    }

    /// `run` in two at its first comma, its first "and" or its mixed token, or `nil`.
    private static func split(_ run: Range<Int>, in words: [Word]) -> (Range<Int>, Range<Int>)? {
        if let comma = run.dropLast().first(where: { !words[$0].trailing.isEmpty }) {
            return (run.lowerBound..<comma + 1, comma + 1..<run.upperBound)
        }
        if let and = run.first(where: { words[$0].text == NumberWords.and }) {
            return (run.lowerBound..<and, and + 1..<run.upperBound)
        }
        if let mixed = run.first(where: { words[$0].startsToken && words[$0].inMixedToken }), mixed > run.lowerBound {
            return (run.lowerBound..<mixed, mixed..<run.upperBound)
        }
        return nil
    }

    /// What `run` says as one number, or `nil` when it makes none. `previous` is the reading
    /// before it, which may make it a time.
    private static func reading(of run: Range<Int>, in words: [Word], after previous: Reading?) -> Reading? {
        let said = run.map { words[$0].text }
        let after = text(after: run.upperBound - 1, in: words)
        if let after, ordinals.contains(after) || after == "o'clock" || after == "o\u{2019}clock"
            || saysAndAHalf(after: run, in: words) {
            return Reading(words: run, text: nil, kind: .other)
        }
        if let decade = decadeOrCentury(run, said: said, in: words) { return decade }
        if let comma = run.dropLast().last(where: { words[$0].trailing == "," }) {
            // Only hundreds may follow a comma: "two thousand, five hundred".
            guard run[(comma + 1)...].contains(where: { NumberWords.isMultiplier(words[$0].text) }) else { return nil }
            return wholeNumber(run, said: said, in: words)
        }
        // A number that runs into a word such as "twelve-year-olds" is a count, never a time,
        // digits said one by one or a year: "twenty twelve-year-olds" is 20 of them.
        let intoMixedToken = run.dropFirst().contains { words[$0].startsToken && words[$0].inMixedToken }
        if !intoMixedToken, let time = time(run, said: said, in: words, after: previous) { return time }
        if said.contains(NumberWords.point) { return decimal(run, said: said, in: words) }
        if !intoMixedToken, let digits = NumberWords.digitString(said) {
            return Reading(words: run, text: digits, kind: .other)
        }
        if !intoMixedToken, let year = NumberWords.year(said) {
            return Reading(words: run, text: String(year), kind: .other)
        }
        return wholeNumber(run, said: said, in: words)
    }

    /// A decade or a century said with its first two digits, and the plural after it: "nineteen
    /// nineties" → "1990s", "eighteen hundreds" → "1800s".
    private static func decadeOrCentury(_ run: Range<Int>, said: [String], in words: [Word]) -> Reading? {
        guard let plural = text(after: run.upperBound - 1, in: words), let century = NumberWords.cardinal(said),
              (10...99).contains(century)
        else { return nil }
        let tens: Int
        if plural == "hundreds" {
            tens = 0
        } else if let decade = decades[plural] {
            tens = decade
        } else {
            return nil
        }
        return Reading(words: run.lowerBound..<run.upperBound + 1, text: "\(century * 100 + tens)s", kind: .other)
    }

    /// "Twelve and a half", "two and a quarter".
    private static func saysAndAHalf(after run: Range<Int>, in words: [Word]) -> Bool {
        let last = run.upperBound - 1
        return text(after: last, in: words) == NumberWords.and && text(after: last + 1, in: words) == "a"
            && ["half", "quarter"].contains(text(after: last + 2, in: words) ?? "")
    }

    /// A clock time: an hour and minutes after a word such as "at", or before "am" or "pm", where
    /// an hour alone is enough too. "At nine fifteen year olds" stays a count, and "at five fifty
    /// dollars" is no time.
    private static func time(_ run: Range<Int>, said: [String], in words: [Word], after previous: Reading?) -> Reading? {
        let after = text(after: run.upperBound - 1, in: words)
        let beforeMeridiem = after.map(meridiems.contains) ?? false
        var afterTime = false
        if let previous, case .time = previous.kind {
            afterTime = previous.words.upperBound == run.lowerBound - 1
        }
        var cued = beforeMeridiem
        if let before = text(before: run.lowerBound, in: words) {
            cued = cued || timeCues.contains(before) || (afterTime && timeLinks.contains(before))
        }
        guard cued, after != "year", after != "years", unit(after: run.upperBound - 1, in: words) == nil else {
            return nil
        }
        if let time = NumberWords.clockTime(said) { return Reading(words: run, text: time, kind: .time) }
        if beforeMeridiem, said.count == 1, let hour = NumberWords.hour(said[0]) {
            return Reading(words: run, text: String(hour), kind: .time)
        }
        return nil
    }

    /// A decimal or a version, with a unit after a decimal.
    private static func decimal(_ run: Range<Int>, said: [String], in words: [Word]) -> Reading? {
        guard let pointed = NumberWords.pointed(said) else { return nil }
        guard !pointed.isVersion else { return Reading(words: run, text: pointed.text, kind: .other) }
        guard let (unit, end) = unit(after: run.upperBound - 1, in: words) else {
            return Reading(words: run, text: pointed.text, kind: .plain(digits: pointed.text, value: nil))
        }
        // Dollars take two decimal places: "$2.50".
        let cents = unit == .dollars && pointed.scale == nil && pointed.fractions[0].count == 1 ? "0" : ""
        return Reading(words: run.lowerBound..<end, text: unit.written(pointed.text + cents), kind: .unit(unit))
    }

    /// A whole number: a count, or an amount with a unit. "A hundred" counts only before a unit or
    /// with more number words after it: "a hundred and fifty".
    private static func wholeNumber(_ run: Range<Int>, said: [String], in words: [Word]) -> Reading? {
        var start = run.lowerBound
        var value = NumberWords.cardinal(said)
        let before = text(before: run.lowerBound, in: words)
        if value == nil, before == "a", NumberWords.isMultiplier(said[0]),
           said.count > 1 || unit(after: run.upperBound - 1, in: words) != nil {
            value = NumberWords.cardinal(["one"] + said)
            start -= 1
        }
        guard let value else { return nil }
        let digits = NumberWords.written(value, saidWith: said)
        guard let (unit, end) = unit(after: run.upperBound - 1, in: words) else {
            if before == "version" { return Reading(words: run, text: digits, kind: .other) }
            return Reading(
                words: start..<run.upperBound, text: value >= 10 ? digits : nil, kind: .plain(digits: digits, value: value)
            )
        }
        if unit == .dollars, let (cents, centsEnd) = cents(after: end - 1, in: words) {
            return Reading(words: start..<centsEnd, text: "$\(digits).\(cents < 10 ? "0" : "")\(cents)", kind: .unit(.dollars))
        }
        return Reading(words: start..<end, text: unit.written(digits), kind: .unit(unit))
    }

    /// The unit after word `index` and the end of the words it replaces: "percent" and "per
    /// cent" become "%" and "dollars" "$", while "cents" stays.
    private static func unit(after index: Int, in words: [Word]) -> (Unit, Int)? {
        switch text(after: index, in: words) {
        case "percent": return (.percent, index + 2)
        case "per": return text(after: index + 1, in: words) == "cent" ? (.percent, index + 3) : nil
        case "dollar", "dollars": return (.dollars, index + 2)
        case "cent", "cents": return (.cents, index + 1)
        default: return nil
        }
    }

    /// The cents after word `index`, "dollars": their number and the end of the words. With
    /// "cents" they are 1 to 99, "and" or not ("and fifty cents"); without it, 10 to 99, straight
    /// after "dollars" ("two dollars fifty") or after "and" at the end of a clause ("two dollars
    /// and fifty.").
    private static func cents(after index: Int, in words: [Word]) -> (Int, Int)? {
        let saysAnd = text(after: index, in: words) == NumberWords.and
        let start = index + (saysAnd ? 2 : 1)
        guard start < words.count, words[start - 1].runsOn else { return nil }
        var end = start
        while end < words.count, NumberWords.isNumberWord(words[end].text), words[end - 1].runsOn {
            end += 1
        }
        guard end > start, let value = NumberWords.cardinal(words[start..<end].map(\.text)), value < 100 else {
            return nil
        }
        if ["cent", "cents"].contains(text(after: end - 1, in: words) ?? "") { return (value, end + 1) }
        guard value >= 10, !saysAnd || !words[end - 1].runsOn else { return nil }
        return (value, end)
    }

    // MARK: - Ranges and clock phrases

    /// What links two readings side by side: "to", "or", "and", "past", or a comma; `nil` when
    /// they are not.
    private static func link(_ left: Reading, _ right: Reading, in words: [Word]) -> String? {
        let last = words[left.words.upperBound - 1]
        if right.words.lowerBound == left.words.upperBound {
            return last.trailing == "," && !last.separatedFromNext ? "," : nil
        }
        guard right.words.lowerBound == left.words.upperBound + 1, last.runsOn, words[left.words.upperBound].runsOn
        else { return nil }
        return words[left.words.upperBound].text
    }

    /// Leaves clock phrases as said: "half past ten", "quarter to eleven", "twenty past twelve".
    private static func keepClockPhrases(_ readings: inout [Reading], in words: [Word]) {
        for index in readings.indices {
            guard case .plain(_, let hour?) = readings[index].kind, (1...12).contains(hour), readings[index].words.count == 1
            else { continue }
            let start = readings[index].words.lowerBound
            guard let connector = text(before: start, in: words), connector == "past" || connector == "to" else { continue }
            if ["half", "quarter"].contains(text(before: start - 1, in: words) ?? "") {
                readings[index].text = nil
                readings[index].kind = .other
            } else if index > 0, case .plain(_, let minutes?) = readings[index - 1].kind, clockMinutes.contains(minutes),
                      link(readings[index - 1], readings[index], in: words) == connector {
                for clock in [index - 1, index] {
                    readings[clock].text = nil
                    readings[clock].kind = .other
                }
            }
        }
    }

    /// A scale word that ends the last number of a range carries back to a smaller first number
    /// said without one: "twenty to thirty thousand" → "20,000 to 30,000", "five or six hundred"
    /// → "500 or 600". Without it, "20 to 30,000" would say a different range.
    private static func carryScalesBack(_ readings: inout [Reading], in words: [Word]) {
        for index in readings.indices.dropFirst() {
            guard case .plain(_, let first?) = readings[index - 1].kind, first > 0,
                  !readings[index - 1].words.contains(where: { NumberWords.isMultiplier(words[$0].text) }),
                  let link = link(readings[index - 1], readings[index], in: words), rangeLinks.contains(link),
                  let (scale, leading) = scale(of: readings[index], in: words), first < leading
            else { continue }
            let value = first * (NumberWords.scales[scale] ?? 100)
            let digits = NumberWords.written(value, saidWith: [scale])
            readings[index - 1].text = digits
            readings[index - 1].kind = .plain(digits: digits, value: value)
        }
    }

    /// The word that multiplies the whole number `reading` says, and the number before it: "thirty
    /// thousand dollars" → "thousand" and 30; `nil` for a decimal, a number with more than one
    /// multiplier ("two thousand five hundred"), or anything but a count or an amount.
    private static func scale(of reading: Reading, in words: [Word]) -> (String, Int)? {
        switch reading.kind {
        case .plain(_, _?), .unit: break
        default: return nil
        }
        let said = reading.words.map { words[$0].text }
        guard !said.contains(NumberWords.point) else { return nil }
        let numberWords = said.filter(NumberWords.isNumberWord)
        guard numberWords.count > 1, let scale = numberWords.last, NumberWords.isMultiplier(scale) else { return nil }
        let before = Array(numberWords.dropLast())
        guard !before.contains(where: NumberWords.isMultiplier), let leading = NumberWords.cardinal(before) else {
            return nil
        }
        return (scale, leading)
    }

    /// A unit after the last number of a range carries back to the first: "five to ten percent"
    /// → "5% to 10%", "five or six dollars" → "$5 or $6".
    private static func carryUnitsBack(_ readings: inout [Reading], in words: [Word]) {
        for index in readings.indices.dropFirst() {
            guard case .unit(let unit) = readings[index].kind, case .plain(let digits, _) = readings[index - 1].kind,
                  let link = link(readings[index - 1], readings[index], in: words), rangeLinks.contains(link)
            else { continue }
            readings[index - 1].text = unit.written(digits)
            readings[index - 1].kind = .unit(unit)
        }
    }

    /// A range or series of counts stays words when any count in it does: "five to ten", "eight,
    /// nine, ten". Two numbers with only a comma between are no series: "One, twenty eggs" is a
    /// list marker and a count, and "In two thousand, five people came" a year and a count.
    private static func keepRangesWithSmallCounts(_ readings: inout [Reading], in words: [Word]) {
        var series: [Int] = []
        var commas = 0
        func close() {
            let isSeries = series.count > 2 || (series.count == 2 && commas == 0)
            if isSeries, series.contains(where: { isSmallCount(readings[$0]) }) {
                for index in series { readings[index].text = nil }
            }
            series = []
            commas = 0
        }
        for index in readings.indices {
            guard case .plain(_, _?) = readings[index].kind else {
                close()
                continue
            }
            if let last = series.last, let link = link(readings[last], readings[index], in: words),
               link == "," || rangeLinks.contains(link) {
                series.append(index)
                if link == "," { commas += 1 }
            } else {
                close()
                series = [index]
            }
        }
        close()
    }

    /// A count below ten, which stays a word.
    private static func isSmallCount(_ reading: Reading) -> Bool {
        guard case .plain(_, let value?) = reading.kind else { return false }
        return value < 10
    }
}
