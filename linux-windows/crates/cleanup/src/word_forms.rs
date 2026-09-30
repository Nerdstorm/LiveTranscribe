//! What Deep's check (`SelfRepair`) knows about English words: which carry facts no repair may
//! change (numbers, dates and times), which a grammar fix may add, drop or swap, and which
//! spellings are forms of the same word. Every word is normalised, as
//! [`lt_shared::edit_distance::normalize`] leaves it, and compared as Swift compares strings, by
//! canonical equivalence.

mod lists;

use std::collections::HashMap;
use std::sync::LazyLock;

use lt_shared::swift_string::{self as s};

use crate::words::{WordSet, same};

static TIME_WORDS: LazyLock<WordSet> = LazyLock::new(|| WordSet::new(lists::TIME_WORDS));
static MONTH_NAMES: LazyLock<WordSet> = LazyLock::new(|| WordSet::new(lists::MONTH_NAMES));
static PARTS_OF_DAY: LazyLock<WordSet> = LazyLock::new(|| WordSet::new(lists::PARTS_OF_DAY));
static QUANTITY_WORDS: LazyLock<WordSet> = LazyLock::new(|| WordSet::new(lists::QUANTITY_WORDS));
static UNIT_WORDS: LazyLock<WordSet> = LazyLock::new(|| WordSet::new(lists::UNIT_WORDS));
static INSERTABLE: LazyLock<WordSet> = LazyLock::new(|| WordSet::new(lists::INSERTABLE));
static DROPPABLE: LazyLock<WordSet> = LazyLock::new(|| WordSet::new(lists::DROPPABLE));
static LIST_MARKERS: LazyLock<WordSet> = LazyLock::new(|| WordSet::new(lists::LIST_MARKERS));

static UNITS: LazyLock<NumberTable> = LazyLock::new(|| NumberTable::new(&lists::UNITS));
static TEENS: LazyLock<NumberTable> = LazyLock::new(|| NumberTable::new(&lists::TEENS));
static TENS: LazyLock<NumberTable> = LazyLock::new(|| NumberTable::new(&lists::TENS));
static ORDINALS: LazyLock<NumberTable> = LazyLock::new(|| NumberTable::new(&lists::ORDINALS));
static SCALES: LazyLock<NumberTable> = LazyLock::new(|| NumberTable::new(&lists::SCALES));

/// For each word of [`lists::FORMS`] and [`lists::IRREGULAR_VERBS`], the others of every group it
/// is in.
static RELATED: LazyLock<HashMap<&'static str, WordSet>> = LazyLock::new(|| {
    let mut related: HashMap<&'static str, Vec<&'static str>> = HashMap::new();
    for group in lists::FORMS.iter().chain(&lists::IRREGULAR_VERBS) {
        let words: Vec<&'static str> = group.split(' ').collect();
        for &word in &words {
            related
                .entry(word)
                .or_default()
                .extend(words.iter().filter(|&&other| other != word));
        }
    }
    related
        .into_iter()
        .map(|(word, others)| (word, WordSet::new(others)))
        .collect()
});

// MARK: - Facts

/// A word that says when: a repair may not add, drop or change one outside a correction, since
/// "the day before" is not "the day after".
pub(crate) fn is_time_word(word: &str) -> bool {
    TIME_WORDS.contains(word)
}

/// A month other than "may", which only its capital or context shows to be one.
pub(crate) fn is_month_name(word: &str) -> bool {
    MONTH_NAMES.contains(word)
}

pub(crate) fn is_part_of_day(word: &str) -> bool {
    PARTS_OF_DAY.contains(word)
}

/// A unit, written as a symbol next to digits ("percent" → "%"), which a repair keeps as said.
pub(crate) fn is_unit_word(word: &str) -> bool {
    UNIT_WORDS.contains(word)
}

/// A number: digits, or a word for one.
pub(crate) fn is_number(word: &str) -> bool {
    s::any_character(word, s::is_number)
        || [&UNITS, &TEENS, &TENS, &ORDINALS, &SCALES]
            .into_iter()
            .any(|table| table.value(word).is_some())
        || QUANTITY_WORDS.contains(word)
}

/// A number word with no digits ("five", not "5").
pub(crate) fn is_number_word(word: &str) -> bool {
    !s::any_character(word, s::is_number) && is_number(word)
}

/// The value of a number written in digits ("25", "21st", "230" from "2:30"), or of a run of
/// number words ("twenty five", "twenty first", "two thirty"), in one form for both, so the two
/// can be compared; `None` when it isn't one number.
pub(crate) fn value<W: AsRef<str>>(words: &[W]) -> Option<String> {
    let first = words.first()?.as_ref();
    let has_digits = |word: &W| s::any_character(word.as_ref(), s::is_number);
    if words.len() == 1 && has_digits(&words[0]) {
        return digits_value(first);
    }
    if words.iter().any(has_digits) {
        return None;
    }
    if let Some((number, ordinal)) = cardinal(words) {
        return Some(if ordinal {
            format!("{number}th")
        } else {
            number.to_string()
        });
    }
    clock_value(words)
}

/// Number words and their values, found as a Swift dictionary finds a key: by canonical
/// equivalence.
struct NumberTable(HashMap<&'static str, i64>);

impl NumberTable {
    fn new(entries: &[(&'static str, i64)]) -> Self {
        Self(entries.iter().copied().collect())
    }

    fn value(&self, word: &str) -> Option<i64> {
        self.0.get(s::canonical_key(word).as_ref()).copied()
    }
}

/// "25" → "25", "21st" → "21th"; `None` for digits Swift's `Int` doesn't read (other scripts' or
/// too many) or an ending that isn't an ordinal's.
fn digits_value(word: &str) -> Option<String> {
    let digits = s::prefix_while(word, s::is_number);
    let number: i64 = digits.parse().ok()?;
    let suffix = &word[digits.len()..];
    if suffix.is_empty() {
        return Some(number.to_string());
    }
    ["st", "nd", "rd", "th"]
        .into_iter()
        .any(|ending| same(suffix, ending))
        .then(|| format!("{number}th"))
}

/// What came last in a number said in words, which decides what may follow it.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Last {
    Nothing,
    Unit,
    Teen,
    Tens,
    Hundred,
    Scale,
}

/// "one hundred twenty five" → 125; "twenty first" → 21, ordinal. Refuses runs that are no one
/// number, such as "five five".
fn cardinal<W: AsRef<str>>(words: &[W]) -> Option<(i64, bool)> {
    use Last::{Hundred, Nothing, Scale, Teen, Tens, Unit};
    let (mut total, mut current) = (0_i64, 0_i64);
    let mut last = Nothing;
    for (offset, word) in words.iter().enumerate() {
        let word = word.as_ref();
        let is_last = offset == words.len() - 1;
        if let Some(unit) = UNITS.value(word).filter(|_| !same(word, "oh")) {
            if !matches!(last, Nothing | Tens | Hundred | Scale) || (unit == 0 && words.len() > 1) {
                return None;
            }
            current += unit;
            last = Unit;
        } else if let Some(teen) = TEENS.value(word) {
            if !matches!(last, Nothing | Hundred | Scale) {
                return None;
            }
            current += teen;
            last = Teen;
        } else if let Some(ten) = TENS.value(word) {
            if !matches!(last, Nothing | Hundred | Scale) {
                return None;
            }
            current += ten;
            last = Tens;
        } else if let Some(ordinal) = ORDINALS.value(word).filter(|_| is_last) {
            let fits_after_tens = ordinal < 10 && last == Tens;
            if !(matches!(last, Nothing | Hundred | Scale) || fits_after_tens) {
                return None;
            }
            return Some((total + current + ordinal, true));
        } else if same(word, "hundred") {
            if !matches!(last, Nothing | Unit | Teen) {
                return None;
            }
            current = current.max(1) * 100;
            last = Hundred;
        } else {
            let scale = SCALES.value(word)?;
            if last == Scale {
                return None;
            }
            total += current.max(1) * scale;
            current = 0;
            last = Scale;
        }
    }
    Some((total + current, false))
}

/// "two thirty" → 230 and "nine oh five" → 905, as "2:30" and "9:05" read once their colon is gone.
fn clock_value<W: AsRef<str>>(words: &[W]) -> Option<String> {
    if words.len() < 2 {
        return None;
    }
    let first = words[0].as_ref();
    let hour = UNITS.value(first).or_else(|| TEENS.value(first))?;
    if !(1..=12).contains(&hour) {
        return None;
    }
    let oh_minutes = (same(words[1].as_ref(), "oh") && words.len() == 3)
        .then(|| UNITS.value(words[2].as_ref()))
        .flatten()
        .filter(|&unit| unit > 0);
    let minutes = oh_minutes.or_else(|| match cardinal(&words[1..]) {
        Some((value, false)) if (10..=59).contains(&value) => Some(value),
        _ => None,
    })?;
    Some((hour * 100 + minutes).to_string())
}

// MARK: - Grammar

/// A word a grammar fix may add: an article, an auxiliary, or a preposition or conjunction that
/// holds a clause together ("I going" → "I am going"). No negation, no word of time.
pub(crate) fn is_insertable(word: &str) -> bool {
    INSERTABLE.contains(word)
}

/// A word a grammar fix may drop without changing what was said.
pub(crate) fn is_droppable(word: &str) -> bool {
    DROPPABLE.contains(word)
}

/// A word said to mark a list item, which a list's own numbers or bullets replace: "first",
/// "secondly", "finally", and "number" (as in "number one", whose number goes too).
pub(crate) fn is_list_marker(word: &str) -> bool {
    LIST_MARKERS.contains(word)
}

/// Whether `lhs` and `rhs` are forms of one word ("check", "checked"; "go", "went"; "is", "are"),
/// or words speech-to-text confuses ("their", "there").
pub(crate) fn are_forms(lhs: &str, rhs: &str) -> bool {
    if RELATED
        .get(s::canonical_key(lhs).as_ref())
        .is_some_and(|related| related.contains(rhs))
    {
        return true;
    }
    let (shorter, longer) = if s::character_count(lhs) <= s::character_count(rhs) {
        (lhs, rhs)
    } else {
        (rhs, lhs)
    };
    let longer_stems = stems(longer);
    stems(shorter)
        .iter()
        .any(|stem| longer_stems.iter().any(|other| same(stem, other)))
}

/// `word` and what it is with a regular ending taken off ("checked" → "check", "tries" → "try",
/// "making" → "make", "stopped" → "stop"). Stems shorter than three letters are left out, so
/// "bed" is not "be".
fn stems(word: &str) -> Vec<String> {
    let mut stems = vec![word.to_owned()];
    let mut add = |stem: String| {
        if s::character_count(&stem) >= 3 {
            stems.push(stem);
        }
    };
    let count = s::character_count(word);
    for suffix in ["ing", "ed", "es", "s"] {
        if !(s::has_suffix(word, suffix) && count > suffix.len() + 2) {
            continue;
        }
        let stem = s::drop_last(word, suffix.len());
        add(stem.to_owned());
        if suffix == "ing" || suffix == "ed" {
            add(format!("{stem}e"));
            let before_last = s::drop_last(stem, 1);
            if let (Some(last), Some(before)) = (s::last_character(stem), s::last_character(before_last))
                && s::canonically_equal(before, last)
            {
                add(before_last.to_owned());
            }
        }
    }
    if s::has_suffix(word, "ies") || s::has_suffix(word, "ied") {
        add(format!("{}y", s::drop_last(word, 3)));
    }
    stems
}

// MARK: - Contractions

/// The two words `word` contracts, where it is a contraction: "don't" → ["do", "not"], "it's" →
/// ["it", "is"] or ["it", "has"], "won't" → ["will", "not"].
pub(crate) fn expansions(word: &str) -> Vec<[String; 2]> {
    let pair = |first: &str, second: &str| [first.to_owned(), second.to_owned()];
    let irregular: [(&[&str], &[[&str; 2]]); 5] = [
        (&["won't"], &[["will", "not"]]),
        (&["can't", "cannot"], &[["can", "not"]]),
        (&["shan't"], &[["shall", "not"]]),
        (&["let's"], &[["let", "us"]]),
        (&["ain't"], &[["am", "not"], ["is", "not"], ["are", "not"]]),
    ];
    if let Some((_, meanings)) = irregular
        .iter()
        .find(|(words, _)| words.iter().any(|&contraction| same(word, contraction)))
    {
        return meanings.iter().map(|[first, second]| pair(first, second)).collect();
    }
    let endings: [(&str, &[&str]); 7] = [
        ("n't", &["not"]),
        ("'re", &["are"]),
        ("'ve", &["have"]),
        ("'ll", &["will", "shall"]),
        ("'d", &["would", "had"]),
        ("'m", &["am"]),
        ("'s", &["is", "has"]),
    ];
    let count = s::character_count(word);
    for (ending, meanings) in endings {
        let length = s::character_count(ending);
        if s::has_suffix(word, ending) && count > length {
            let stem = s::drop_last(word, length);
            return meanings.iter().map(|meaning| pair(stem, meaning)).collect();
        }
    }
    Vec::new()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn value_of(words: &str) -> Option<String> {
        value(&words.split(' ').collect::<Vec<_>>())
    }

    #[test]
    fn numbers_in_words_and_digits_have_one_value() {
        for (words, expected) in [
            ("25", Some("25")),
            ("twenty five", Some("25")),
            ("21st", Some("21th")),
            ("twenty first", Some("21th")),
            ("one hundred twenty five", Some("125")),
            ("two thousand and", None),
            ("230", Some("230")),
            ("two thirty", Some("230")),
            ("nine oh five", Some("905")),
            ("thirteen fifteen", None),
            ("five five", None),
            ("zero", Some("0")),
            ("zero one", None),
            ("oh", None),
            ("twenty", Some("20")),
            ("first", Some("1th")),
            ("5x", None),
            ("٧", None),
            ("99999999999999999999", None),
            ("half", None),
        ] {
            assert_eq!(value_of(words).as_deref(), expected, "{words}");
        }
    }

    #[test]
    fn number_words_are_numbers_without_digits() {
        assert!(is_number("7") && !is_number_word("7"));
        assert!(is_number("seven") && is_number_word("seven"));
        assert!(is_number("oh") && is_number("dozen") && is_number("hundred"));
        assert!(!is_number("dollars") && is_unit_word("dollars"));
        assert!(!is_number("may"));
    }

    #[test]
    fn forms_of_a_word() {
        for (lhs, rhs) in [
            ("check", "checked"),
            ("go", "went"),
            ("is", "are"),
            ("their", "there"),
            ("try", "tries"),
            ("make", "making"),
            ("stop", "stopped"),
            ("bus", "buses"),
            ("don't", "doesn't"),
            ("same", "same"),
        ] {
            assert!(are_forms(lhs, rhs) && are_forms(rhs, lhs), "{lhs} {rhs}");
        }
        for (lhs, rhs) in [("bed", "be"), ("before", "after"), ("don't", "do"), ("sing", "sin")] {
            assert!(!are_forms(lhs, rhs), "{lhs} {rhs}");
        }
    }

    #[test]
    fn contractions_expand_to_their_words() {
        let expanded = |word: &str| expansions(word);
        assert_eq!(expanded("don't"), [["do", "not"]]);
        assert_eq!(expanded("won't"), [["will", "not"]]);
        assert_eq!(expanded("cannot"), [["can", "not"]]);
        assert_eq!(expanded("it's"), [["it", "is"], ["it", "has"]]);
        assert_eq!(expanded("ain't"), [["am", "not"], ["is", "not"], ["are", "not"]]);
        assert_eq!(expanded("they'll"), [["they", "will"], ["they", "shall"]]);
        assert!(expanded("'s").is_empty() && expanded("not").is_empty());
    }

    #[test]
    fn word_lists_find_canonically_equivalent_words() {
        assert!(is_time_word("tomorrow") && !is_time_word("today's"));
        assert!(is_month_name("june") && !is_month_name("may"));
        assert!(is_part_of_day("o'clock") && is_insertable("am") && is_droppable("really"));
        assert!(is_list_marker("secondly") && !is_list_marker("one"));
    }
}
