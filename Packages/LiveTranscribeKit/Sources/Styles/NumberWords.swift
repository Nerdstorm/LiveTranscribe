import Foundation

/// The spoken number words ``NumberStyle`` reads, and the numbers they make. Each reader takes
/// lowercased words and reads all of them as one number, or returns `nil`.
enum NumberWords {
    static let digits: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
    ]
    static let teens: [String: Int] = [
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
        "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]
    static let hundred = "hundred"
    static let scales: [String: Int] = ["thousand": 1_000, "million": 1_000_000, "billion": 1_000_000_000]
    /// Zero, but only among digits said one by one ("three oh two"), in a year ("twenty oh five"),
    /// a time ("twelve oh five") or a decimal's digits ("two point oh").
    static let oh = "oh"
    static let and = "and"
    static let point = "point"
    /// The first two digits of a year said in halves: 1900 to 2099.
    private static let centuries: [String: Int] = ["nineteen": 19, "twenty": 20]

    /// Whether `word` can be part of a spoken number.
    static func isNumberWord(_ word: String) -> Bool {
        digits[word] != nil || teens[word] != nil || tens[word] != nil || word == hundred || scales[word] != nil
            || word == oh
    }

    /// Whether `word` multiplies the number before it: "hundred", "thousand", "million", "billion".
    static func isMultiplier(_ word: String) -> Bool {
        word == hundred || scales[word] != nil
    }

    /// The whole number `words` say: "one hundred and twenty five" → 125, "fifteen hundred" →
    /// 1500, "two thousand and eight" → 2008, "zero" → 0. "And" may follow "hundred" or a scale
    /// word, and scale words must get smaller ("thousand" after "million").
    static func cardinal(_ words: [String]) -> Int? {
        if words == ["zero"] { return 0 }
        var index = 0
        var total = 0
        var lastScale = Int.max
        while index < words.count {
            guard let (section, next) = section(words, from: index) else { return nil }
            index = next
            guard index < words.count else { return total + section }
            guard let scale = scales[words[index]], scale < lastScale else { return nil }
            total += section * scale
            lastScale = scale
            index += 1
            if index < words.count, words[index] == and {
                guard let (rest, end) = small(words, from: index + 1), end == words.count else { return nil }
                return total + rest
            }
        }
        return total
    }

    /// A year said in two halves, from 1900 to 2099: "nineteen ninety nine", "twenty twenty six",
    /// "twenty oh five". "Two thousand and eight" is a ``cardinal(_:)``.
    static func year(_ words: [String]) -> Int? {
        guard words.count >= 2, let century = centuries[words[0]] else { return nil }
        guard let rest = twoDigits(Array(words.dropFirst())) else { return nil }
        return century * 100 + rest
    }

    /// A clock time from an hour (one to twelve) and its minutes: "nine fifteen" → "9:15",
    /// "twelve oh five" → "12:05".
    static func clockTime(_ words: [String]) -> String? {
        guard words.count >= 2, let hour = hour(words[0]), let minutes = twoDigits(Array(words.dropFirst())),
              minutes < 60
        else { return nil }
        return "\(hour):" + (minutes < 10 ? "0" : "") + String(minutes)
    }

    /// An hour on a twelve-hour clock, said in one word: "one" to "twelve".
    static func hour(_ word: String) -> Int? {
        if let digit = digits[word], digit > 0 { return digit }
        if let teen = teens[word], teen <= 12 { return teen }
        return nil
    }

    /// Single digits said one by one, three or more of them: "zero four four six" → "0446",
    /// "three oh two" → "302". "Oh" counts as zero, but "oh oh oh" alone is not a number.
    static func digitString(_ words: [String]) -> String? {
        guard words.count >= 3, words.contains(where: { digits[$0] != nil }) else { return nil }
        return digitsSaidOneByOne(words)
    }

    /// A decimal or a version, said with "point": "two point five" → 2 and ["5"], "one point one
    /// point zero" → 1 and ["1", "0"]. The whole part is any ``cardinal(_:)``; each part after a
    /// "point" is digits said one by one ("three point one four") or a number from 10 to 99
    /// ("one point twelve"). A decimal may end with a scale word ("two point five million"),
    /// which ``Pointed/scale`` keeps.
    static func pointed(_ words: [String]) -> Pointed? {
        var parts = words.split(separator: point, omittingEmptySubsequences: false).map(Array.init)
        guard parts.count >= 2, let whole = cardinal(parts[0]) else { return nil }
        var scale: String?
        if parts.count == 2, let last = parts[1].last, scales[last] != nil {
            scale = last
            parts[1].removeLast()
        }
        var fractions: [String] = []
        for part in parts.dropFirst() {
            if let digits = digitsSaidOneByOne(part) {
                fractions.append(digits)
            } else if let (value, end) = small(part, from: 0), end == part.count, value >= 10 {
                fractions.append(String(value))
            } else {
                return nil
            }
        }
        return Pointed(whole: whole, fractions: fractions, scale: scale)
    }

    /// What ``pointed(_:)`` read.
    struct Pointed {
        let whole: Int
        /// The digits after each "point": one part for a decimal, two or more for a version.
        let fractions: [String]
        /// "thousand", "million" or "billion" after a decimal, kept as a word.
        let scale: String?

        var isVersion: Bool { fractions.count > 1 }

        /// "2.5", "2.4.1", "2.5 million".
        var text: String {
            ([NumberWords.grouped(whole)] + fractions).joined(separator: ".") + (scale.map { " " + $0 } ?? "")
        }
    }

    /// `value` in digits, with commas between thousands from 10,000 up, so a four-digit count
    /// reads like a year: 2026, 1500, 50,000, 1,200,000.
    static func grouped(_ value: Int) -> String {
        let digits = String(value)
        guard value >= 10_000 else { return digits }
        var result = ""
        for (index, digit) in digits.enumerated() {
            if index > 0, (digits.count - index) % 3 == 0 { result.append(",") }
            result.append(digit)
        }
        return result
    }

    /// A count in digits. Whole millions or billions said with the word keep it: "five million"
    /// → "5 million", "two hundred and fifty million" → "250 million"; any other number is
    /// ``grouped(_:)``.
    static func written(_ value: Int, saidWith words: [String]) -> String {
        if let last = words.last, let scale = scales[last], scale >= 1_000_000,
           value % scale == 0, value / scale < 1_000 {
            return "\(value / scale) \(last)"
        }
        return grouped(value)
    }

    // MARK: - Private

    /// 1 to 9999 said as "seven", "forty two", "three hundred and five" or "fifteen hundred",
    /// starting at word `start`: its value and the index of the word after it.
    private static func section(_ words: [String], from start: Int) -> (Int, Int)? {
        guard let (lead, next) = small(words, from: start) else { return nil }
        guard next < words.count, words[next] == hundred else { return (lead, next) }
        let value = lead * 100
        let index = next + 1
        if index < words.count, words[index] == and {
            guard let (rest, end) = small(words, from: index + 1) else { return nil }
            return (value + rest, end)
        }
        if let (rest, end) = small(words, from: index) { return (value + rest, end) }
        return (value, index)
    }

    /// 1 to 99 said as "seven", "fifteen", "forty" or "forty two", starting at word `start`: its
    /// value and the index of the word after it.
    private static func small(_ words: [String], from start: Int) -> (Int, Int)? {
        guard start < words.count else { return nil }
        let word = words[start]
        if let digit = digits[word], digit > 0 { return (digit, start + 1) }
        if let teen = teens[word] { return (teen, start + 1) }
        guard let ten = tens[word] else { return nil }
        if start + 1 < words.count, let digit = digits[words[start + 1]], digit > 0 {
            return (ten + digit, start + 2)
        }
        return (ten, start + 1)
    }

    /// The last two digits of a year or a time's minutes: 10 to 99 ("twenty six", "fifteen"),
    /// or "oh" and a digit ("oh five" → 5).
    private static func twoDigits(_ words: [String]) -> Int? {
        if words.count == 2, words[0] == oh, let digit = digits[words[1]], digit > 0 { return digit }
        guard let (value, end) = small(words, from: 0), end == words.count, value >= 10 else { return nil }
        return value
    }

    /// The digits of words that are each a single digit or "oh": "three oh two" → "302".
    private static func digitsSaidOneByOne(_ words: [String]) -> String? {
        guard !words.isEmpty else { return nil }
        var result = ""
        for word in words {
            if word == oh {
                result += "0"
            } else if let digit = digits[word] {
                result += String(digit)
            } else {
                return nil
            }
        }
        return result
    }
}
