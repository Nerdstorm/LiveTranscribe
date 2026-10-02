use std::collections::HashSet;
use std::ops::Range;

use lt_shared::swift_string::{self as s};

use crate::number_words::{self as numbers, AND, OH, POINT};

mod words;

use words::{Word, text_after, text_before, words};

/// Idioms whose numbers stay words.
pub const NUMBER_IDIOMS: [&str; 4] = [
    "forty winks",
    "hindsight is twenty twenty",
    "twenty twenty hindsight",
    "twenty twenty vision",
];

/// Words before a time: "at nine fifteen".
const TIME_CUES: [&str; 8] = ["at", "by", "from", "until", "till", "around", "before", "after"];
/// Words between two times: "from nine thirty to ten fifteen".
const TIME_LINKS: [&str; 5] = ["to", "and", "or", "until", "till"];
const MERIDIEMS: [&str; 4] = ["am", "pm", "a.m", "p.m"];
/// Words that make two numbers a range or a series, besides a comma.
const RANGE_LINKS: [&str; 3] = ["to", "or", "and"];
/// Minutes said before "past" or "to" in a clock phrase: "twenty past ten".
const CLOCK_MINUTES: [u64; 4] = [5, 10, 20, 25];
const ORDINALS: [&str; 31] = [
    "first",
    "second",
    "third",
    "fourth",
    "fifth",
    "sixth",
    "seventh",
    "eighth",
    "ninth",
    "tenth",
    "eleventh",
    "twelfth",
    "thirteenth",
    "fourteenth",
    "fifteenth",
    "sixteenth",
    "seventeenth",
    "eighteenth",
    "nineteenth",
    "twentieth",
    "thirtieth",
    "fortieth",
    "fiftieth",
    "sixtieth",
    "seventieth",
    "eightieth",
    "ninetieth",
    "hundredth",
    "thousandth",
    "millionth",
    "billionth",
];

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
///   cents" → "$5.50", "fifty cents" → "50 cents";
/// - times, after "at", "by", "from", "until", "till", "around", "before" or "after", or before
///   "am" or "pm": "at nine fifteen" → "at 9:15", "seven thirty pm" → "7:30 pm";
/// - years said in halves, 1900 to 2099: "in twenty twenty six" → "in 2026".
///
/// Other numbers are counts: one to nine stay words, 10 and up become digits ("twenty one chairs"
/// → "21 chairs"). Numbers of five digits or more take commas (50,000) and four-digit ones don't,
/// so a count reads like a year (1500, 2026); whole millions and billions keep the word ("5
/// million"). A number that starts a sentence is written the same way.
///
/// Number words are read in any case ("Zero Four Four Six") and hyphenated ("twenty-one",
/// "twenty-five-year-old" → "25-year-old"). Punctuation or a line break ends a number, except a
/// comma after "thousand", "million" or "billion" before more hundreds ("two thousand, five
/// hundred" → "2500").
///
/// These stay as said:
/// - "one" and every count below ten, so list markers that were not laid out stay words ("One, go
///   to shops, two, …") and lists that were start with digits already ("1. ");
/// - number words that make no one number: "nine eleven", "twenty four seven", "nine fifteen" with
///   no "at" or "pm";
/// - a number before an ordinal ("twenty first"), "o'clock" or "and a half", in a clock phrase
///   ("half past ten", "twenty to eleven"), and "a hundred" or "a thousand" except before
///   "dollars" or "percent";
/// - a range or series with a count below ten: "five to ten", "nine or ten", "eight, nine, ten"
///   (but "ten to fifteen" → "10 to 15"); a unit after the last number carries back, "five to ten
///   percent" → "5% to 10%";
/// - idioms ([`NUMBER_IDIOMS`]) and the phrases the rule is told to keep, such as vocabulary
///   terms.
#[derive(Clone, Debug)]
pub struct NumberStyle {
    /// The words of each phrase that keeps its numbers as written, lowercased.
    kept_phrases: Vec<Vec<String>>,
}

impl Default for NumberStyle {
    fn default() -> Self {
        Self::keeping::<&str>(&[])
    }
}

impl NumberStyle {
    /// `phrases` keep their numbers as written, such as vocabulary terms ("Studio Fifty-Four"),
    /// matched in any case. The [`NUMBER_IDIOMS`] are kept too.
    pub fn keeping<S: AsRef<str>>(phrases: &[S]) -> Self {
        let kept_phrases = NUMBER_IDIOMS
            .iter()
            .copied()
            .chain(phrases.iter().map(AsRef::as_ref))
            .map(|phrase| words(phrase).into_iter().map(|word| word.text).collect::<Vec<_>>())
            .filter(|phrase| phrase.iter().any(|word| numbers::is_number_word(word)))
            .collect();
        Self { kept_phrases }
    }

    /// `text` with its spoken numbers written as the type describes.
    pub fn written(&self, text: &str) -> String {
        let words = words(text);
        if !words.iter().any(|word| numbers::is_number_word(&word.text)) {
            return text.to_owned();
        }
        let kept = self.kept_words(&words);

        let mut readings: Vec<Reading> = Vec::new();
        let mut read_up_to = 0;
        for run in runs(&words, &kept) {
            if run.start < read_up_to {
                continue;
            }
            read(run, &words, &mut readings);
            read_up_to = readings.last().map_or(read_up_to, |reading| reading.words.end);
        }
        keep_clock_phrases(&mut readings, &words);
        carry_units_back(&mut readings, &words);
        keep_ranges_with_small_counts(&mut readings, &words);

        let mut result = String::new();
        let mut position = 0;
        for reading in &readings {
            let Some(replacement) = &reading.text else {
                continue;
            };
            let start = words[reading.words.start].range.start;
            result.push_str(&text[position..start]);
            result.push_str(replacement);
            position = words[reading.words.end - 1].range.end;
        }
        result.push_str(&text[position..]);
        result
    }

    /// Indices of the words in a kept phrase or idiom.
    fn kept_words(&self, words: &[Word]) -> HashSet<usize> {
        let mut kept = HashSet::new();
        for phrase in &self.kept_phrases {
            if phrase.len() > words.len() {
                continue;
            }
            for start in 0..=(words.len() - phrase.len()) {
                if phrase
                    .iter()
                    .enumerate()
                    .all(|(offset, word)| words[start + offset].text == *word)
                {
                    kept.extend(start..start + phrase.len());
                }
            }
        }
        kept
    }
}

fn is_in(word: Option<&str>, set: &[&str]) -> bool {
    word.is_some_and(|word| set.contains(&word))
}

// MARK: - Runs

/// Runs of number words that may make one number. A run starts a token and goes on over spaces
/// and hyphens; "and" after "hundred" or a scale word, "point" between numbers, and a comma after
/// a scale word may join it to more number words. A token that mixes number words with others
/// ends a run.
fn runs(words: &[Word], kept: &HashSet<usize>) -> Vec<Range<usize>> {
    let mut runs = Vec::new();
    let mut index = 0;
    while index < words.len() {
        if !words[index].starts_token || kept.contains(&index) || !numbers::is_number_word(&words[index].text) {
            index += 1;
            continue;
        }
        let mut end = index + 1;
        while let Some(next) = continuation(end - 1, words, kept) {
            end = next;
        }
        runs.push(index..end);
        index = end;
    }
    runs
}

/// The end of the run when it goes on past word `index`: one past the next word, or past the
/// "and" or "point" and the word after it; `None` when the run ends at `index`.
fn continuation(index: usize, words: &[Word], kept: &HashSet<usize>) -> Option<usize> {
    let next = index + 1;
    if next >= words.len() || kept.contains(&next) {
        return None;
    }
    let previous = &words[index];
    let word = &words[next];
    if previous.in_mixed_token && word.starts_token {
        return None;
    }
    if !previous.runs_on() {
        let joins_across_comma = s::canonically_equal(previous.trailing, ",")
            && !previous.separated_from_next
            && numbers::scale(&previous.text).is_some()
            && numbers::is_number_word(&word.text)
            && word.text != OH;
        return joins_across_comma.then_some(next + 1);
    }
    if numbers::is_number_word(&word.text) {
        return Some(next + 1);
    }
    let joiner = (word.text == AND && numbers::is_multiplier(&previous.text))
        || (word.text == POINT && numbers::is_number_word(&previous.text));
    if !joiner || !word.runs_on() || next + 1 >= words.len() || kept.contains(&(next + 1)) {
        return None;
    }
    let after = words[next + 1].text.as_str();
    let continues =
        numbers::is_number_word(after) && !numbers::is_multiplier(after) && (after != OH || word.text == POINT);
    continues.then_some(next + 2)
}

// MARK: - Readings

#[derive(Clone, Copy, PartialEq, Eq)]
enum Unit {
    Percent,
    Dollars,
    Cents,
}

impl Unit {
    /// `digits` with the unit's sign: "25%", "$125", or "50" before "cents".
    fn written(self, digits: &str) -> String {
        match self {
            Self::Percent => format!("{digits}%"),
            Self::Dollars => format!("${digits}"),
            Self::Cents => digits.to_owned(),
        }
    }
}

#[derive(Clone)]
enum Kind {
    /// A number said without a unit: `value` for a whole number, `None` for a decimal.
    Plain {
        digits: String,
        value: Option<u64>,
    },
    Unit(Unit),
    Time,
    /// Digits said one by one, a year, a version, or words that stay as said.
    Other,
}

/// What a run says, and the words it replaces.
#[derive(Clone)]
struct Reading {
    /// The run, with the "a" before or the unit words after it that it took.
    words: Range<usize>,
    /// What replaces the words, or `None` to leave them as said.
    text: Option<String>,
    kind: Kind,
}

impl Reading {
    fn new(words: Range<usize>, text: Option<String>, kind: Kind) -> Self {
        Self { words, text, kind }
    }

    /// Words that stay as said.
    fn as_said(words: Range<usize>) -> Self {
        Self::new(words, None, Kind::Other)
    }

    /// A count below ten, which stays a word.
    fn is_small_count(&self) -> bool {
        matches!(self.kind, Kind::Plain { value: Some(value), .. } if value < 10)
    }
}

/// Appends what `run` says to `readings`. A run that makes no one number is split where a comma,
/// "and" or a mixed token joined it, and its parts are read on their own.
fn read(run: Range<usize>, words: &[Word], readings: &mut Vec<Reading>) {
    if let Some(reading) = reading(run.clone(), words, readings.last()) {
        readings.push(reading);
        return;
    }
    let Some((left, right)) = split(run.clone(), words) else {
        readings.push(Reading::as_said(run));
        return;
    };
    read(left, words, readings);
    read(right, words, readings);
}

/// `run` in two at its first comma, its first "and" or its mixed token, or `None`.
fn split(run: Range<usize>, words: &[Word]) -> Option<(Range<usize>, Range<usize>)> {
    if let Some(comma) = (run.start..run.end - 1).find(|&index| !words[index].trailing.is_empty()) {
        return Some((run.start..comma + 1, comma + 1..run.end));
    }
    if let Some(and) = run.clone().find(|&index| words[index].text == AND) {
        return Some((run.start..and, and + 1..run.end));
    }
    if let Some(mixed) = run
        .clone()
        .find(|&index| words[index].starts_token && words[index].in_mixed_token)
        && mixed > run.start
    {
        return Some((run.start..mixed, mixed..run.end));
    }
    None
}

/// What `run` says as one number, or `None` when it makes none. `previous` is the reading before
/// it, which may make it a time.
fn reading(run: Range<usize>, words: &[Word], previous: Option<&Reading>) -> Option<Reading> {
    let said: Vec<&str> = words[run.clone()].iter().map(|word| word.text.as_str()).collect();
    if let Some(after) = text_after(run.end - 1, words)
        && (ORDINALS.contains(&after)
            || s::canonically_equal(after, "o'clock")
            || s::canonically_equal(after, "o\u{2019}clock")
            || says_and_a_half(&run, words))
    {
        return Some(Reading::as_said(run));
    }
    if let Some(comma) = (run.start..run.end - 1)
        .rev()
        .find(|&index| s::canonically_equal(words[index].trailing, ","))
    {
        // Only hundreds may follow a comma: "two thousand, five hundred".
        if !(comma + 1..run.end).any(|index| numbers::is_multiplier(&words[index].text)) {
            return None;
        }
        return whole_number(run, &said, words);
    }
    if let Some(time) = time(run.clone(), &said, words, previous) {
        return Some(time);
    }
    if said.contains(&POINT) {
        return decimal(run, &said, words);
    }
    if let Some(digits) = numbers::digit_string(&said) {
        return Some(Reading::new(run, Some(digits), Kind::Other));
    }
    if let Some(year) = numbers::year(&said) {
        return Some(Reading::new(run, Some(year.to_string()), Kind::Other));
    }
    whole_number(run, &said, words)
}

/// "Twelve and a half", "two and a quarter".
fn says_and_a_half(run: &Range<usize>, words: &[Word]) -> bool {
    let last = run.end - 1;
    text_after(last, words) == Some(AND)
        && text_after(last + 1, words) == Some("a")
        && is_in(text_after(last + 2, words), &["half", "quarter"])
}

/// A clock time: an hour and minutes after a word such as "at", or before "am" or "pm", where an
/// hour alone is enough too. "At nine fifteen year olds" stays a count.
fn time(run: Range<usize>, said: &[&str], words: &[Word], previous: Option<&Reading>) -> Option<Reading> {
    let after = text_after(run.end - 1, words);
    let before_meridiem = is_in(after, &MERIDIEMS);
    let after_time =
        previous.is_some_and(|previous| matches!(previous.kind, Kind::Time) && previous.words.end + 1 == run.start);
    let mut cued = before_meridiem;
    if let Some(before) = text_before(run.start, words) {
        cued = cued || TIME_CUES.contains(&before) || (after_time && TIME_LINKS.contains(&before));
    }
    if !cued || is_in(after, &["year", "years"]) {
        return None;
    }
    if let Some(time) = numbers::clock_time(said) {
        return Some(Reading::new(run, Some(time), Kind::Time));
    }
    if before_meridiem
        && said.len() == 1
        && let Some(hour) = numbers::hour(said[0])
    {
        return Some(Reading::new(run, Some(hour.to_string()), Kind::Time));
    }
    None
}

/// A decimal or a version, with a unit after a decimal.
fn decimal(run: Range<usize>, said: &[&str], words: &[Word]) -> Option<Reading> {
    let pointed = numbers::pointed(said)?;
    let text = pointed.text();
    if pointed.is_version() {
        return Some(Reading::new(run, Some(text), Kind::Other));
    }
    let Some((unit, end)) = unit_after(run.end - 1, words) else {
        return Some(Reading::new(
            run,
            Some(text.clone()),
            Kind::Plain {
                digits: text,
                value: None,
            },
        ));
    };
    // Dollars take two decimal places: "$2.50".
    let cents = if unit == Unit::Dollars && pointed.scale.is_none() && pointed.fractions[0].len() == 1 {
        "0"
    } else {
        ""
    };
    Some(Reading::new(
        run.start..end,
        Some(unit.written(&format!("{text}{cents}"))),
        Kind::Unit(unit),
    ))
}

/// A whole number: a count, or an amount with a unit. "A hundred" counts only before a unit.
fn whole_number(run: Range<usize>, said: &[&str], words: &[Word]) -> Option<Reading> {
    let mut start = run.start;
    let mut value = numbers::cardinal(said);
    let before = text_before(run.start, words);
    if value.is_none()
        && before == Some("a")
        && numbers::is_multiplier(said[0])
        && unit_after(run.end - 1, words).is_some()
    {
        let with_one: Vec<&str> = std::iter::once("one").chain(said.iter().copied()).collect();
        value = numbers::cardinal(&with_one);
        start -= 1;
    }
    let value = value?;
    let digits = numbers::written(value, said);
    let Some((unit, end)) = unit_after(run.end - 1, words) else {
        if before == Some("version") {
            return Some(Reading::new(run, Some(digits), Kind::Other));
        }
        return Some(Reading::new(
            run,
            (value >= 10).then(|| digits.clone()),
            Kind::Plain {
                digits,
                value: Some(value),
            },
        ));
    };
    if unit == Unit::Dollars
        && let Some((cents, cents_end)) = cents_after(end - 1, words)
    {
        return Some(Reading::new(
            start..cents_end,
            Some(format!("${digits}.{cents:02}")),
            Kind::Unit(Unit::Dollars),
        ));
    }
    Some(Reading::new(start..end, Some(unit.written(&digits)), Kind::Unit(unit)))
}

/// The unit after word `index` and the end of the words it replaces: "percent" and "per cent"
/// become "%" and "dollars" "$", while "cents" stays.
fn unit_after(index: usize, words: &[Word]) -> Option<(Unit, usize)> {
    match text_after(index, words)? {
        "percent" => Some((Unit::Percent, index + 2)),
        "per" => (text_after(index + 1, words) == Some("cent")).then_some((Unit::Percent, index + 3)),
        "dollar" | "dollars" => Some((Unit::Dollars, index + 2)),
        "cent" | "cents" => Some((Unit::Cents, index + 1)),
        _ => None,
    }
}

/// The cents in "and fifty cents" after word `index`, "dollars": their number, 1 to 99, and the
/// end of the words.
fn cents_after(index: usize, words: &[Word]) -> Option<(u64, usize)> {
    if text_after(index, words) != Some(AND) {
        return None;
    }
    let mut end = index + 2;
    while end < words.len() && numbers::is_number_word(&words[end].text) && words[end - 1].runs_on() {
        end += 1;
    }
    if end <= index + 2 || !is_in(text_after(end - 1, words), &["cent", "cents"]) {
        return None;
    }
    let value = numbers::cardinal(
        &words[index + 2..end]
            .iter()
            .map(|word| word.text.as_str())
            .collect::<Vec<_>>(),
    )
    .filter(|&value| value < 100)?;
    Some((value, end + 1))
}

// MARK: - Ranges and clock phrases

/// What links two readings side by side: "to", "or", "and", "past", or a comma; `None` when they
/// are not.
fn link<'w>(left: &Reading, right: &Reading, words: &'w [Word]) -> Option<&'w str> {
    let last = &words[left.words.end - 1];
    if right.words.start == left.words.end {
        return (s::canonically_equal(last.trailing, ",") && !last.separated_from_next).then_some(",");
    }
    if right.words.start != left.words.end + 1 || !last.runs_on() || !words[left.words.end].runs_on() {
        return None;
    }
    Some(words[left.words.end].text.as_str())
}

/// Leaves clock phrases as said: "half past ten", "quarter to eleven", "twenty past twelve".
fn keep_clock_phrases(readings: &mut [Reading], words: &[Word]) {
    for index in 0..readings.len() {
        let is_hour = matches!(readings[index].kind, Kind::Plain { value: Some(hour), .. } if (1..=12).contains(&hour));
        if !is_hour || readings[index].words.len() != 1 {
            continue;
        }
        let start = readings[index].words.start;
        let Some(connector) = text_before(start, words).filter(|&connector| connector == "past" || connector == "to")
        else {
            continue;
        };
        if is_in(text_before(start - 1, words), &["half", "quarter"]) {
            readings[index].text = None;
            readings[index].kind = Kind::Other;
        } else if index > 0
            && matches!(readings[index - 1].kind, Kind::Plain { value: Some(minutes), .. } if CLOCK_MINUTES.contains(&minutes))
            && link(&readings[index - 1], &readings[index], words) == Some(connector)
        {
            for clock in [index - 1, index] {
                readings[clock].text = None;
                readings[clock].kind = Kind::Other;
            }
        }
    }
}

/// A unit after the last number of a range carries back to the first: "five to ten percent" → "5%
/// to 10%", "five or six dollars" → "$5 or $6".
fn carry_units_back(readings: &mut [Reading], words: &[Word]) {
    for index in 1..readings.len() {
        let Kind::Unit(unit) = readings[index].kind else {
            continue;
        };
        let Kind::Plain { digits, .. } = &readings[index - 1].kind else {
            continue;
        };
        if !is_in(link(&readings[index - 1], &readings[index], words), &RANGE_LINKS) {
            continue;
        }
        readings[index - 1].text = Some(unit.written(digits));
        readings[index - 1].kind = Kind::Unit(unit);
    }
}

/// A range or series of counts stays words when any count in it does: "five to ten", "eight, nine,
/// ten". Two numbers with only a comma between are no series: "One, twenty eggs" is a list marker
/// and a count, and "In two thousand, five people came" a year and a count.
fn keep_ranges_with_small_counts(readings: &mut [Reading], words: &[Word]) {
    fn close(readings: &mut [Reading], series: &mut Vec<usize>, commas: &mut usize) {
        let is_series = series.len() > 2 || (series.len() == 2 && *commas == 0);
        if is_series && series.iter().any(|&index| readings[index].is_small_count()) {
            for &index in series.iter() {
                readings[index].text = None;
            }
        }
        series.clear();
        *commas = 0;
    }

    let mut series: Vec<usize> = Vec::new();
    let mut commas = 0;
    for index in 0..readings.len() {
        if !matches!(readings[index].kind, Kind::Plain { value: Some(_), .. }) {
            close(readings, &mut series, &mut commas);
            continue;
        }
        let linked = series
            .last()
            .and_then(|&last| link(&readings[last], &readings[index], words));
        if let Some(link) = linked.filter(|&link| link == "," || RANGE_LINKS.contains(&link)) {
            series.push(index);
            if link == "," {
                commas += 1;
            }
        } else {
            close(readings, &mut series, &mut commas);
            series.push(index);
        }
    }
    close(readings, &mut series, &mut commas);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn writes_spoken_numbers_in_digits() {
        let style = NumberStyle::default();
        for (text, written) in [
            ("My PIN is Zero Four Four Six.", "My PIN is 0446."),
            ("version two point four point one", "version 2.4.1"),
            ("one hundred and twenty five dollars", "$125"),
            ("I agree a hundred percent.", "I agree 100%."),
            ("from nine thirty to ten fifteen", "from 9:30 to 10:15"),
            ("in twenty twenty six", "in 2026"),
            ("Twenty one people came.", "21 people came."),
            ("fifty thousand, I mean sixty thousand", "50,000, I mean 60,000"),
            ("nine fifteen-year-olds", "nine 15-year-olds"),
            ("between five and ten percent", "between 5% and 10%"),
            (
                "We need three things:\n1. Twenty eggs\n2. Milk",
                "We need three things:\n1. 20 eggs\n2. Milk",
            ),
        ] {
            assert_eq!(style.written(text), written, "{text:?}");
        }
    }

    #[test]
    fn leaves_words_that_are_not_one_number() {
        let style = NumberStyle::default();
        for text in [
            "the one I want",
            "one point I would make",
            "nine eleven",
            "five to ten",
            "eight, nine, ten",
            "half past ten",
            "the twenty first century",
            "hindsight is twenty twenty",
            "One, go to shops, two, talk to mechanic.",
        ] {
            assert_eq!(style.written(text), text);
        }
    }

    #[test]
    fn kept_phrases_stay_as_written() {
        let style = NumberStyle::keeping(&["Studio Fifty-Four"]);
        assert_eq!(
            style.written("meet at Studio Fifty-Four at nine thirty"),
            "meet at Studio Fifty-Four at 9:30"
        );
        assert_eq!(style.written("fifty four people"), "54 people");
    }
}
