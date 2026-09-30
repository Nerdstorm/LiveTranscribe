use std::ops::Range;

use lt_shared::placeholder_token;
use lt_shared::swift_string::{self as s};

/// The letters an alias may start with, in the order they are tried.
const LETTERS: [&str; 5] = ["S", "T", "P", "Q", "Z"];

/// Placeholder tokens as the cleanup model sees them: short words ("S1", "S2") instead of the
/// bracketed tokens (`⟦S1⟧`) the rest of dictation uses.
///
/// The model treats the brackets as noise. In the Mac app's prompt probe it stripped or dropped 17
/// of 23 bracketed tokens, and kept 21 of 23 of the same tokens written as words. So the executor
/// writes each token as its alias before the model runs, and puts the tokens back in the output
/// before the guard reviews it. The guard, and everything after it, sees only tokens.
///
/// An alias must not already be a word in the text, or that word would become a token on the way
/// back, so the letter changes until none is: "the S1 form" gets T1, T2, and so on.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct PlaceholderAliases {
    /// Each token and the word the model sees for it, in the order the tokens were given.
    pairs: Vec<(String, String)>,
}

impl PlaceholderAliases {
    /// Aliases for `tokens`, the placeholder tokens in `text`, the text the model will see.
    pub(crate) fn new(tokens: &[String], text: &str) -> Self {
        if tokens.is_empty() {
            return Self { pairs: Vec::new() };
        }
        let visible = tokens.iter().fold(text.to_owned(), |visible, token| {
            s::replacing_occurrences(&visible, token, " ")
        });
        let words: Vec<String> = s::split_where(&visible, usize::MAX, true, |c| !s::is_letter(c) && !s::is_number(c))
            .into_iter()
            .map(s::uppercased)
            .collect();
        let letter = LETTERS
            .into_iter()
            .find(|&letter| !words.iter().any(|word| looks_like_an_alias(word, letter)));
        let Some(letter) = letter else {
            // Words like S1, T1, P1, Q1 and Z1 all in one text: the model sees the tokens.
            tracing::info!("No free alias letter for placeholders; the model sees the tokens");
            return Self {
                pairs: tokens.iter().map(|token| (token.clone(), token.clone())).collect(),
            };
        };
        Self {
            pairs: tokens
                .iter()
                .enumerate()
                .map(|(index, token)| (token.clone(), format!("{letter}{}", index + 1)))
                .collect(),
        }
    }

    /// The words the model sees, in the order of the tokens.
    pub(crate) fn aliases(&self) -> Vec<String> {
        self.pairs.iter().map(|(_, alias)| alias.clone()).collect()
    }

    /// `text` with each token replaced by its alias.
    pub(crate) fn aliased(&self, text: &str) -> String {
        self.pairs.iter().fold(text.to_owned(), |text, (token, alias)| {
            s::replacing_occurrences(&text, token, alias)
        })
    }

    /// `output` with each alias that appears exactly once, as a whole word in any case, replaced by
    /// its token. An alias the model dropped or repeated is left as it is, so the guard, which
    /// counts tokens, rejects the output.
    pub(crate) fn restored(&self, output: &str) -> String {
        let mut restored = output.to_owned();
        for (token, alias) in &self.pairs {
            if s::canonically_equal(alias, token) {
                continue;
            }
            if let [range] = whole_word_ranges(alias, &restored).as_slice() {
                restored.replace_range(range.clone(), token);
            }
        }
        restored
    }
}

/// Whether `word`, uppercased, is `letter` followed by digits, as an alias is.
fn looks_like_an_alias(word: &str, letter: &str) -> bool {
    s::character_count(word) > 1
        && s::first_character(word).is_some_and(|first| s::canonically_equal(first, letter))
        && s::characters(word).skip(1).all(s::is_number)
}

/// Where `word` appears in `text` with no letter, digit or token bracket either side, ignoring
/// case, as Foundation's case-insensitive `range(of:)` finds it: character by character, and
/// never overlapping, even with a match that was not a whole word.
fn whole_word_ranges(word: &str, text: &str) -> Vec<Range<usize>> {
    let wanted: Vec<&str> = s::characters(word).collect();
    if wanted.is_empty() {
        return Vec::new();
    }
    let found: Vec<(usize, &str)> = s::character_indices(text).collect();
    let mut ranges = Vec::new();
    let mut index = 0;
    while index + wanted.len() <= found.len() {
        let window = &found[index..index + wanted.len()];
        if !window
            .iter()
            .zip(&wanted)
            .all(|(&(_, character), expected)| equal_ignoring_case(character, expected))
        {
            index += 1;
            continue;
        }
        let before = index.checked_sub(1).map(|previous| found[previous].1);
        let after = found.get(index + wanted.len()).map(|&(_, character)| character);
        if !joins_word(before) && !joins_word(after) {
            let (last, character) = window[window.len() - 1];
            ranges.push(window[0].0..last + character.len());
        }
        index += wanted.len();
    }
    ranges
}

/// Whether two characters are the same ignoring case. Foundation folds case, so "ſ" (long s)
/// matches "S" too. An alias is one letter and digits, which this covers; it is not a general
/// case-insensitive comparison of strings.
fn equal_ignoring_case(a: &str, b: &str) -> bool {
    let fold = |character: &str| s::lowercased(&s::uppercased(character));
    s::canonically_equal(&fold(a), &fold(b))
}

fn joins_word(character: Option<&str>) -> bool {
    character.is_some_and(|character| {
        s::is_letter(character)
            || s::is_number(character)
            || s::canonically_equal(character, placeholder_token::OPENING)
            || s::canonically_equal(character, placeholder_token::CLOSING)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn aliases(tokens: &[&str], text: &str) -> PlaceholderAliases {
        let tokens: Vec<String> = tokens.iter().map(|&token| token.to_owned()).collect();
        PlaceholderAliases::new(&tokens, text)
    }

    #[test]
    fn the_model_sees_a_word_for_each_token() {
        let aliases = aliases(&["⟦S1⟧", "⟦S2⟧"], "send ⟦S1⟧ to ⟦S2⟧");
        assert_eq!(aliases.aliases(), ["S1", "S2"]);
        assert_eq!(aliases.aliased("send ⟦S1⟧ to ⟦S2⟧"), "send S1 to S2");
    }

    #[test]
    fn an_alias_is_never_a_word_already_in_the_text() {
        let aliases = aliases(&["⟦S1⟧"], "fill in the s1 form and send ⟦S1⟧");
        assert_eq!(aliases.aliases(), ["T1"]);
        assert_eq!(
            aliases.restored("Fill in the S1 form and send T1."),
            "Fill in the S1 form and send ⟦S1⟧."
        );
    }

    #[test]
    fn with_no_free_letter_the_model_sees_the_tokens() {
        let aliases = aliases(&["⟦S1⟧"], "S1 T2 P3 Q4 Z5 ⟦S1⟧");
        assert_eq!(aliases.aliases(), ["⟦S1⟧"]);
        assert_eq!(aliases.restored("S1 T2 P3 Q4 Z5 ⟦S1⟧"), "S1 T2 P3 Q4 Z5 ⟦S1⟧");
    }

    #[test]
    fn restores_whole_words_in_any_case() {
        let aliases = aliases(&["⟦S1⟧", "⟦S2⟧"], "send ⟦S1⟧ to ⟦S2⟧");
        assert_eq!(aliases.restored("Send s1 to S2's desk."), "Send ⟦S1⟧ to ⟦S2⟧'s desk.");
    }

    #[test]
    fn an_alias_inside_a_longer_word_is_not_restored() {
        let tokens: Vec<String> = (1..=12).map(placeholder_token::make).collect();
        let aliases = PlaceholderAliases::new(&tokens, &tokens.join(" "));
        let reversed: Vec<String> = aliases.aliases().into_iter().rev().collect();
        let tokens_reversed: Vec<String> = tokens.iter().rev().cloned().collect();
        assert_eq!(aliases.restored(&reversed.join(" ")), tokens_reversed.join(" "));
    }

    /// The guard counts tokens, so leaving these as words makes it reject the output.
    #[test]
    fn a_dropped_or_repeated_alias_is_left_for_the_guard() {
        let aliases = aliases(&["⟦S1⟧", "⟦S2⟧"], "send ⟦S1⟧ to ⟦S2⟧");
        assert_eq!(aliases.restored("Send S1 to S1."), "Send S1 to S1.");
        assert_eq!(aliases.restored("Send it."), "Send it.");
    }

    #[test]
    fn without_tokens_nothing_changes() {
        let aliases = aliases(&[], "send it");
        assert!(aliases.aliases().is_empty());
        assert_eq!(aliases.aliased("send it"), "send it");
        assert_eq!(aliases.restored("Send S1."), "Send S1.");
    }

    /// Foundation's case-insensitive search folds case ("ſ" is an "s") and matches whole
    /// characters ("1" with a combining accent is another character).
    #[test]
    fn case_is_ignored_as_foundation_ignores_it() {
        let aliases = aliases(&["⟦S1⟧"], "send ⟦S1⟧");
        assert_eq!(aliases.restored("Send \u{17F}1."), "Send ⟦S1⟧.");
        assert_eq!(aliases.restored("Send S1\u{301} now."), "Send S1\u{301} now.");
        assert_eq!(aliases.restored("Send Ｓ1."), "Send Ｓ1.");
    }

    /// A word like "S²" is an alias to the check, since "²" is a number to Swift.
    #[test]
    fn any_number_after_the_letter_takes_the_letter() {
        assert_eq!(aliases(&["⟦S1⟧"], "the s² form ⟦S1⟧").aliases(), ["T1"]);
        assert_eq!(aliases(&["⟦S1⟧"], "the s form ⟦S1⟧").aliases(), ["S1"]);
    }
}
