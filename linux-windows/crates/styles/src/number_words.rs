//! The spoken number words [`NumberStyle`](crate::NumberStyle) reads, and the numbers they make.
//! Each reader takes lowercased words and reads all of them as one number, or returns `None`.

pub(crate) const HUNDRED: &str = "hundred";
/// Zero, but only among digits said one by one ("three oh two"), in a year ("twenty oh five"), a
/// time ("twelve oh five") or a decimal's digits ("two point oh").
pub(crate) const OH: &str = "oh";
pub(crate) const AND: &str = "and";
pub(crate) const POINT: &str = "point";

pub(crate) fn digit(word: &str) -> Option<u64> {
    Some(match word {
        "zero" => 0,
        "one" => 1,
        "two" => 2,
        "three" => 3,
        "four" => 4,
        "five" => 5,
        "six" => 6,
        "seven" => 7,
        "eight" => 8,
        "nine" => 9,
        _ => return None,
    })
}

fn teen(word: &str) -> Option<u64> {
    Some(match word {
        "ten" => 10,
        "eleven" => 11,
        "twelve" => 12,
        "thirteen" => 13,
        "fourteen" => 14,
        "fifteen" => 15,
        "sixteen" => 16,
        "seventeen" => 17,
        "eighteen" => 18,
        "nineteen" => 19,
        _ => return None,
    })
}

fn ten(word: &str) -> Option<u64> {
    Some(match word {
        "twenty" => 20,
        "thirty" => 30,
        "forty" => 40,
        "fifty" => 50,
        "sixty" => 60,
        "seventy" => 70,
        "eighty" => 80,
        "ninety" => 90,
        _ => return None,
    })
}

pub(crate) fn scale(word: &str) -> Option<u64> {
    Some(match word {
        "thousand" => 1_000,
        "million" => 1_000_000,
        "billion" => 1_000_000_000,
        _ => return None,
    })
}

/// The first two digits of a year said in halves: 1900 to 2099.
fn century(word: &str) -> Option<u64> {
    Some(match word {
        "nineteen" => 19,
        "twenty" => 20,
        _ => return None,
    })
}

/// Whether `word` can be part of a spoken number.
pub(crate) fn is_number_word(word: &str) -> bool {
    digit(word).is_some()
        || teen(word).is_some()
        || ten(word).is_some()
        || word == HUNDRED
        || scale(word).is_some()
        || word == OH
}

/// Whether `word` multiplies the number before it: "hundred", "thousand", "million", "billion".
pub(crate) fn is_multiplier(word: &str) -> bool {
    word == HUNDRED || scale(word).is_some()
}

/// The whole number `words` say: "one hundred and twenty five" → 125, "fifteen hundred" → 1500,
/// "two thousand and eight" → 2008, "zero" → 0. "And" may follow "hundred" or a scale word, and
/// scale words must get smaller ("thousand" after "million").
pub(crate) fn cardinal<S: AsRef<str>>(words: &[S]) -> Option<u64> {
    let words: Vec<&str> = words.iter().map(AsRef::as_ref).collect();
    if words == ["zero"] {
        return Some(0);
    }
    let mut index = 0;
    let mut total = 0;
    let mut last_scale = u64::MAX;
    while index < words.len() {
        let (section, next) = section(&words, index)?;
        index = next;
        if index >= words.len() {
            return Some(total + section);
        }
        let scale = scale(words[index]).filter(|&scale| scale < last_scale)?;
        total += section * scale;
        last_scale = scale;
        index += 1;
        if index < words.len() && words[index] == AND {
            let (rest, end) = small(&words, index + 1)?;
            return (end == words.len()).then_some(total + rest);
        }
    }
    Some(total)
}

/// A year said in two halves, from 1900 to 2099: "nineteen ninety nine", "twenty twenty six",
/// "twenty oh five". "Two thousand and eight" is a [`cardinal`].
pub(crate) fn year(words: &[&str]) -> Option<u64> {
    if words.len() < 2 {
        return None;
    }
    Some(century(words[0])? * 100 + two_digits(&words[1..])?)
}

/// A clock time from an hour (one to twelve) and its minutes: "nine fifteen" → "9:15", "twelve oh
/// five" → "12:05".
pub(crate) fn clock_time(words: &[&str]) -> Option<String> {
    if words.len() < 2 {
        return None;
    }
    let hour = hour(words[0])?;
    let minutes = two_digits(&words[1..]).filter(|&minutes| minutes < 60)?;
    Some(format!("{hour}:{minutes:02}"))
}

/// An hour on a twelve-hour clock, said in one word: "one" to "twelve".
pub(crate) fn hour(word: &str) -> Option<u64> {
    digit(word)
        .filter(|&digit| digit > 0)
        .or_else(|| teen(word).filter(|&teen| teen <= 12))
}

/// Single digits said one by one, three or more of them: "zero four four six" → "0446", "three
/// oh two" → "302". "Oh" counts as zero, but "oh oh oh" alone is not a number.
pub(crate) fn digit_string(words: &[&str]) -> Option<String> {
    if words.len() < 3 || !words.iter().any(|word| digit(word).is_some()) {
        return None;
    }
    digits_said_one_by_one(words)
}

/// What [`pointed`] read.
pub(crate) struct Pointed {
    pub whole: u64,
    /// The digits after each "point": one part for a decimal, two or more for a version.
    pub fractions: Vec<String>,
    /// "thousand", "million" or "billion" after a decimal, kept as a word.
    pub scale: Option<String>,
}

impl Pointed {
    pub fn is_version(&self) -> bool {
        self.fractions.len() > 1
    }

    /// "2.5", "2.4.1", "2.5 million".
    pub fn text(&self) -> String {
        let mut parts = vec![grouped(self.whole)];
        parts.extend(self.fractions.iter().cloned());
        let mut text = parts.join(".");
        if let Some(scale) = &self.scale {
            text.push(' ');
            text.push_str(scale);
        }
        text
    }
}

/// A decimal or a version, said with "point": "two point five" → 2 and ["5"], "one point one
/// point zero" → 1 and ["1", "0"]. The whole part is any [`cardinal`]; each part after a "point"
/// is digits said one by one ("three point one four") or a number from 10 to 99 ("one point
/// twelve"). A decimal may end with a scale word ("two point five million"), which
/// [`Pointed::scale`] keeps.
pub(crate) fn pointed(words: &[&str]) -> Option<Pointed> {
    let mut parts: Vec<Vec<&str>> = words.split(|&word| word == POINT).map(<[&str]>::to_vec).collect();
    if parts.len() < 2 {
        return None;
    }
    let whole = cardinal(&parts[0])?;
    let mut scale_word = None;
    if parts.len() == 2
        && let Some(&last) = parts[1].last()
        && scale(last).is_some()
    {
        scale_word = Some(last.to_owned());
        parts[1].pop();
    }
    let mut fractions = Vec::new();
    for part in &parts[1..] {
        if let Some(digits) = digits_said_one_by_one(part) {
            fractions.push(digits);
        } else if let Some((value, end)) = small(part, 0)
            && end == part.len()
            && value >= 10
        {
            fractions.push(value.to_string());
        } else {
            return None;
        }
    }
    Some(Pointed {
        whole,
        fractions,
        scale: scale_word,
    })
}

/// `value` in digits, with commas between thousands from 10,000 up, so a four-digit count reads
/// like a year: 2026, 1500, 50,000, 1,200,000.
pub(crate) fn grouped(value: u64) -> String {
    let digits = value.to_string();
    if value < 10_000 {
        return digits;
    }
    let mut result = String::new();
    for (index, digit) in digits.chars().enumerate() {
        if index > 0 && (digits.len() - index).is_multiple_of(3) {
            result.push(',');
        }
        result.push(digit);
    }
    result
}

/// A count in digits. Whole millions or billions said with the word keep it: "five million" → "5
/// million", "two hundred and fifty million" → "250 million"; any other number is [`grouped`].
pub(crate) fn written(value: u64, said: &[&str]) -> String {
    if let Some(&last) = said.last()
        && let Some(scale) = scale(last)
        && scale >= 1_000_000
        && value.is_multiple_of(scale)
        && value / scale < 1_000
    {
        return format!("{} {last}", value / scale);
    }
    grouped(value)
}

/// 1 to 9999 said as "seven", "forty two", "three hundred and five" or "fifteen hundred",
/// starting at word `start`: its value and the index of the word after it.
fn section(words: &[&str], start: usize) -> Option<(u64, usize)> {
    let (lead, next) = small(words, start)?;
    if next >= words.len() || words[next] != HUNDRED {
        return Some((lead, next));
    }
    let value = lead * 100;
    let index = next + 1;
    if index < words.len() && words[index] == AND {
        let (rest, end) = small(words, index + 1)?;
        return Some((value + rest, end));
    }
    if let Some((rest, end)) = small(words, index) {
        return Some((value + rest, end));
    }
    Some((value, index))
}

/// 1 to 99 said as "seven", "fifteen", "forty" or "forty two", starting at word `start`: its value
/// and the index of the word after it.
fn small(words: &[&str], start: usize) -> Option<(u64, usize)> {
    let word = *words.get(start)?;
    if let Some(digit) = digit(word).filter(|&digit| digit > 0) {
        return Some((digit, start + 1));
    }
    if let Some(teen) = teen(word) {
        return Some((teen, start + 1));
    }
    let ten = ten(word)?;
    if let Some(digit) = words
        .get(start + 1)
        .and_then(|&next| digit(next))
        .filter(|&digit| digit > 0)
    {
        return Some((ten + digit, start + 2));
    }
    Some((ten, start + 1))
}

/// The last two digits of a year or a time's minutes: 10 to 99 ("twenty six", "fifteen"), or "oh"
/// and a digit ("oh five" → 5).
fn two_digits(words: &[&str]) -> Option<u64> {
    if words.len() == 2
        && words[0] == OH
        && let Some(digit) = digit(words[1]).filter(|&digit| digit > 0)
    {
        return Some(digit);
    }
    let (value, end) = small(words, 0)?;
    (end == words.len() && value >= 10).then_some(value)
}

/// The digits of words that are each a single digit or "oh": "three oh two" → "302".
fn digits_said_one_by_one(words: &[&str]) -> Option<String> {
    if words.is_empty() {
        return None;
    }
    words
        .iter()
        .map(|&word| {
            if word == OH {
                Some('0')
            } else {
                digit(word).and_then(|digit| char::from_digit(u32::try_from(digit).ok()?, 10))
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_whole_numbers() {
        assert_eq!(cardinal(&["one", "hundred", "and", "twenty", "five"]), Some(125));
        assert_eq!(cardinal(&["fifteen", "hundred"]), Some(1500));
        assert_eq!(cardinal(&["two", "thousand", "and", "eight"]), Some(2008));
        assert_eq!(
            cardinal(&["one", "million", "two", "hundred", "thousand"]),
            Some(1_200_000)
        );
        assert_eq!(cardinal(&["nine", "eleven"]), None);
        assert_eq!(cardinal(&["thousand"]), None);
        assert_eq!(grouped(1500), "1500");
        assert_eq!(grouped(1_200_000), "1,200,000");
        assert_eq!(written(5_000_000, &["five", "million"]), "5 million");
    }
}
