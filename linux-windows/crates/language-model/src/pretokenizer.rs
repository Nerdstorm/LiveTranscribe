//! Qwen2's pre-tokenizer, which cuts normalised text into the pieces BPE merges within. It is the
//! pattern the Split step of Qwen's tokenizer.json gives,
//!
//! ```text
//! (?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\r\n\p{L}\p{N}]?\p{L}+|\p{N}| ?[^\s\p{L}\p{N}]+[\r\n]*|\s*[\r\n]+|\s+(?!\S)|\s+
//! ```
//!
//! written out by hand, because the regex crate has no look-ahead (`(?!\S)`). At each position the
//! alternatives are tried in order and the first that matches wins, its quantifiers backing off as
//! a backtracking engine's do: Hugging Face's `tokenizers` runs the pattern with Oniguruma. `\p{L}`
//! and `\p{N}` are Unicode's letter and number categories, and `\s` its White_Space property. The
//! pieces are the matches (the step's `Isolated` behaviour); every character is in one of the
//! alternatives, so nothing falls between them.

use unicode_properties::{GeneralCategoryGroup, UnicodeGeneralCategory};

/// `text` cut into its pieces, which together are `text`.
pub fn split(text: &str) -> Vec<&str> {
    let chars: Vec<char> = text.chars().collect();
    let mut offsets: Vec<usize> = text.char_indices().map(|(offset, _)| offset).collect();
    offsets.push(text.len());
    let mut pieces = Vec::new();
    let mut start = 0;
    while start < chars.len() {
        // Every character starts a match; one character is a safe step if that ever changed.
        let length = piece_at(&chars, start).unwrap_or(1);
        pieces.push(&text[offsets[start]..offsets[start + length]]);
        start += length;
    }
    pieces
}

/// The length, in characters, of the piece that starts at `at`.
fn piece_at(chars: &[char], at: usize) -> Option<usize> {
    contraction(chars, at)
        .or_else(|| letters(chars, at))
        .or_else(|| number(chars, at))
        .or_else(|| symbols(chars, at))
        .or_else(|| line_breaks(chars, at))
        .or_else(|| spaces_before_space(chars, at))
        .or_else(|| spaces(chars, at))
}

/// `(?i:'s|'t|'re|'ve|'m|'ll|'d)`.
fn contraction(chars: &[char], at: usize) -> Option<usize> {
    if chars.get(at) != Some(&'\'') {
        return None;
    }
    let letter = |offset: usize| chars.get(at + offset).map(|&c| fold(c));
    match letter(1)? {
        's' | 't' | 'm' | 'd' => Some(2),
        'r' | 'v' if letter(2) == Some('e') => Some(3),
        'l' if letter(2) == Some('l') => Some(3),
        _ => None,
    }
}

/// The contractions' letters as a case-insensitive match compares them: capitals as small
/// letters, and the long s (ſ), which Unicode folds to s.
fn fold(c: char) -> char {
    if c == 'ſ' { 's' } else { c.to_ascii_lowercase() }
}

/// `[^\r\n\p{L}\p{N}]?\p{L}+`: a run of letters, with the character before it if that is neither a
/// line break, a letter nor a number (such as the space before a word).
fn letters(chars: &[char], at: usize) -> Option<usize> {
    let first = *chars.get(at)?;
    let start = if is_letter(first) {
        at
    } else if !is_line_break(first) && !is_number(first) && chars.get(at + 1).is_some_and(|&c| is_letter(c)) {
        at + 1
    } else {
        return None;
    };
    Some(run_end(chars, start, is_letter) - at)
}

/// `\p{N}`: one number character.
fn number(chars: &[char], at: usize) -> Option<usize> {
    chars.get(at).is_some_and(|&c| is_number(c)).then_some(1)
}

/// ` ?[^\s\p{L}\p{N}]+[\r\n]*`: a run of symbols and punctuation, with a space before it, and the
/// line breaks after it.
fn symbols(chars: &[char], at: usize) -> Option<usize> {
    let is_symbol = |c: char| !is_space(c) && !is_letter(c) && !is_number(c);
    // A space is taken only when a symbol follows: without it, the run can't start at a space.
    let start = if chars.get(at) == Some(&' ') { at + 1 } else { at };
    if !chars.get(start).is_some_and(|&c| is_symbol(c)) {
        return None;
    }
    let end = run_end(chars, start, is_symbol);
    Some(run_end(chars, end, is_line_break) - at)
}

/// `\s*[\r\n]+`: white space up to and including the last line break in it.
fn line_breaks(chars: &[char], at: usize) -> Option<usize> {
    let end = run_end(chars, at, is_space);
    let last_break = (at..end).rev().find(|&index| is_line_break(chars[index]))?;
    Some(last_break + 1 - at)
}

/// `\s+(?!\S)`: white space that isn't followed by anything else, or, when something follows, all
/// of it but its last character, which goes with what follows.
fn spaces_before_space(chars: &[char], at: usize) -> Option<usize> {
    let end = run_end(chars, at, is_space);
    if end == at {
        None
    } else if end == chars.len() {
        Some(end - at)
    } else {
        (end - at > 1).then_some(end - 1 - at)
    }
}

/// `\s+`.
fn spaces(chars: &[char], at: usize) -> Option<usize> {
    let end = run_end(chars, at, is_space);
    (end > at).then_some(end - at)
}

/// Where the run of characters from `start` for which `in_run` holds ends.
fn run_end(chars: &[char], start: usize, in_run: impl Fn(char) -> bool) -> usize {
    chars[start..]
        .iter()
        .position(|&c| !in_run(c))
        .map_or(chars.len(), |length| start + length)
}

fn is_letter(c: char) -> bool {
    c.general_category_group() == GeneralCategoryGroup::Letter
}

fn is_number(c: char) -> bool {
    c.general_category_group() == GeneralCategoryGroup::Number
}

fn is_space(c: char) -> bool {
    c.is_whitespace()
}

fn is_line_break(c: char) -> bool {
    c == '\r' || c == '\n'
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn words_take_the_space_before_them() {
        assert_eq!(split("Hello world"), ["Hello", " world"]);
        assert_eq!(split("hello  world"), ["hello", " ", " world"]);
    }

    #[test]
    fn numbers_are_one_digit_a_piece() {
        assert_eq!(split("12,345.6"), ["1", "2", ",", "3", "4", "5", ".", "6"]);
    }

    #[test]
    fn contractions_are_pieces_of_their_own_in_any_case() {
        assert_eq!(split("I'm DON'T we'll"), ["I", "'m", " DON", "'T", " we", "'ll"]);
    }

    #[test]
    fn line_breaks_end_the_white_space_before_them() {
        assert_eq!(split("a \n\n b"), ["a", " \n\n", " b"]);
        assert_eq!(split("x\n\n"), ["x", "\n\n"]);
    }

    #[test]
    fn trailing_white_space_is_one_piece() {
        assert_eq!(split("end   "), ["end", "   "]);
    }

    #[test]
    fn symbols_keep_the_line_breaks_after_them() {
        assert_eq!(split("TEXT:\nhi"), ["TEXT", ":\n", "hi"]);
        assert_eq!(split(" ?!\n\n"), [" ?!\n\n"]);
    }

    #[test]
    fn joins_the_pieces_back_into_the_text() {
        let text = "ශ්‍රී ලංකාව 🙂 e\u{301}\t\u{a0}x";
        assert_eq!(split(text).concat(), text);
    }
}
