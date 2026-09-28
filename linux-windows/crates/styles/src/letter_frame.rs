use std::ops::Range;

use lt_shared::edit_distance;
use lt_shared::phrase_grammar::{self, is_word_in};
use lt_shared::placeholder_token;
use lt_shared::sentence_case::capitalizing_first_word;
use lt_shared::swift_string::{self as s, CharacterSet};
use lt_shared::{TokenizedText, token_edges};

use crate::layout::{FrameRule, TextFrame};
use crate::list_formatter::ListFormatter;

/// A greeting with no addressee after it.
const IMPERSONAL_GREETING: &[&str] = &["to", "whom", "it", "may", "concern"];
const GREETINGS: &[&[&str]] = &[
    IMPERSONAL_GREETING,
    &["good", "morning"],
    &["good", "afternoon"],
    &["good", "evening"],
    &["dear"],
    &["hi"],
    &["hello"],
    &["hey"],
    &["greetings"],
];
/// Groups addressed by a common word, and how they are written.
const GROUPS: &[(&str, &str)] = &[
    ("sir or madam", "Sir or Madam"),
    ("sir oh madam", "Sir or Madam"),
    ("sir slash madam", "Sir or Madam"),
    ("sir and madam", "Sir and Madam"),
    ("sir", "Sir"),
    ("madam", "Madam"),
    ("sirs", "Sirs"),
    ("hiring manager", "Hiring Manager"),
    ("hiring team", "Hiring Team"),
    ("all", "all"),
    ("team", "team"),
    ("everyone", "everyone"),
    ("everybody", "everybody"),
    ("folks", "folks"),
    ("guys", "guys"),
    ("there", "there"),
    ("both", "both"),
    ("you all", "you all"),
    ("all of you", "all of you"),
    ("colleagues", "colleagues"),
    ("friends", "friends"),
];
/// Most words in a group's name.
const LONGEST_GROUP: usize = 3;
/// Capitalised words that start a body, never a name in a greeting.
const NOT_NAMES: &[&str] = &[
    "i",
    "i'm",
    "i've",
    "i'll",
    "i'd",
    "we",
    "we're",
    "we've",
    "we'll",
    "thanks",
    "thank",
    "hope",
    "hoping",
    "just",
    "please",
    "can",
    "could",
    "would",
    "will",
    "here",
    "this",
    "the",
    "it",
    "it's",
    "is",
    "are",
    "how",
    "what",
    "when",
    "where",
    "why",
    "sorry",
    "good",
    "great",
    "so",
    "quick",
    "following",
    "further",
    "regarding",
    "as",
    "welcome",
    "congratulations",
    "congrats",
    "happy",
    "let",
    "let's",
    "my",
    "our",
    "your",
    "yes",
    "no",
    "ok",
    "okay",
    "hopefully",
    "unfortunately",
    "apologies",
    "attached",
    "today",
];
/// Sign-offs that end a letter with or without a name after them.
const SIGN_OFFS: &[&[&str]] = &[
    &["kind", "regards"],
    &["best", "regards"],
    &["warm", "regards"],
    &["warmest", "regards"],
    &["kindest", "regards"],
    &["regards"],
    &["sincerely"],
    &["yours", "sincerely"],
    &["sincerely", "yours"],
    &["yours", "faithfully"],
    &["yours", "truly"],
    &["best", "wishes"],
    &["with", "best", "wishes"],
    &["all", "the", "best"],
    &["many", "thanks"],
    &["with", "thanks"],
    &["thanks", "and", "regards"],
    &["thanks", "in", "advance"],
    &["respectfully"],
    &["cordially"],
    &["with", "gratitude"],
];
/// Sign-offs that are also everyday words, so they end a letter only before a name or after a
/// body that reads as a letter's (see [`reads_as_a_letter`]).
const EVERYDAY_SIGN_OFFS: &[&[&str]] = &[
    &["thanks"],
    &["thank", "you"],
    &["cheers"],
    &["best"],
    &["love"],
    &["take", "care"],
    &["talk", "soon"],
    &["speak", "soon"],
];
/// Most words in a signature.
const LONGEST_SIGNATURE: usize = 4;
/// Fewest sentences in a body that an everyday sign-off with no name after it ends.
const MINIMUM_LETTER_SENTENCES: usize = 2;
const SENTENCE_ENDERS: [&str; 3] = [".", "!", "?"];

/// A letter or email: a greeting at the start ("Dear Sir or Madam", "Hi John") and a sign-off at
/// the end ("Kind regards Jordan Lee"), laid out on lines of their own around the body.
///
/// Both ends are found in the words before cleanup, and only the body goes to the model: given a
/// whole letter, the model moved the name in the sign-off into the greeting. A letter needs a
/// greeting and a sign-off, so "Hi John, can you send the report?" stays as it is, as a chat
/// message should. An everyday sign-off such as "Thanks", "Cheers" or "Best" ends a letter before
/// a name, or with no name when the body reads as a letter's: two sentences or more, or a spoken
/// list.
///
/// The addressee is what follows the greeting up to its comma, or, when speech-to-text wrote
/// none, the capitalised names or a word such as "team" or "all" right after it. "Dear sir oh
/// madam", a common mishearing, becomes "Dear Sir or Madam".
#[derive(Clone, Copy, Debug, Default)]
pub struct LetterFrame;

/// A laid-out part of the letter and the token where the text around it starts.
struct Part {
    text: String,
    token: usize,
}

impl FrameRule for LetterFrame {
    fn frame(&self, text: &str, list_markers: &[String]) -> Option<TextFrame> {
        let tokenized = TokenizedText::new(text);
        if tokenized.words().first()?.token != 0 {
            return None;
        }
        let greeting = GREETINGS
            .iter()
            .find(|greeting| phrase_grammar::matches(greeting, 0, &tokenized))?;
        let salutation = salutation(greeting, &tokenized)?;
        let sign_off = sign_off(salutation.token, &tokenized, list_markers)?;
        if salutation.token >= sign_off.token {
            return None;
        }

        let body_range = tokenized.tokens()[salutation.token].start..tokenized.tokens()[sign_off.token - 1].end;
        let body = s::trimming(&text[body_range], CharacterSet::WhitespacesAndNewlines);
        if !s::any_character(body, |c| s::is_letter(c) || s::is_number(c)) {
            return None;
        }
        Some(TextFrame {
            opening: salutation.text + "\n\n",
            body: body.to_owned(),
            closing: format!("\n\n{}", sign_off.text),
        })
    }
}

// MARK: - Greeting

/// The salutation line, and the first token of the body.
fn salutation(greeting: &[&str], text: &TokenizedText) -> Option<Part> {
    let greeting_end = text.words()[greeting.len() - 1].token;
    let written = capitalizing_first_word(&greeting.join(" "));
    let first = greeting_end + 1;
    let token_count = text.tokens().len();
    if first >= token_count {
        return None;
    }
    if greeting == IMPERSONAL_GREETING || phrase_grammar::ends_clause(text.token(greeting_end)) {
        return Some(Part {
            text: format!("{written},"),
            token: first,
        });
    }

    // Up to a comma or a placeholder in the next few tokens, if what comes before is an addressee.
    for index in first..(first + LONGEST_GROUP + 1).min(token_count) {
        let token = text.token(index);
        let is_placeholder = s::contains_character(token, placeholder_token::OPENING);
        if !(is_placeholder || phrase_grammar::ends_clause(token)) {
            continue;
        }
        let tokens = first..if is_placeholder { index } else { index + 1 };
        let Some(name) = addressee(tokens.clone(), text) else {
            break;
        };
        if tokens.end >= token_count {
            return None;
        }
        let line = if name.is_empty() {
            format!("{written},")
        } else {
            format!("{written} {name},")
        };
        return Some(Part {
            text: line,
            token: tokens.end,
        });
    }

    // No punctuation: a group word, else the capitalised names right after the greeting.
    for count in (1..=LONGEST_GROUP).rev() {
        if first + count >= token_count {
            continue;
        }
        if let Some(name) = addressee(first..first + count, text)
            && is_group(first..first + count, text)
        {
            return Some(Part {
                text: format!("{written} {name},"),
                token: first + count,
            });
        }
    }
    let mut end = first;
    while end < (first + 3).min(token_count - 1) && is_name(text.token(end)) {
        end += 1;
    }
    if end == first {
        return None;
    }
    let name = addressee(first..end, text)?;
    Some(Part {
        text: format!("{written} {name},"),
        token: end,
    })
}

/// How the addressee in `tokens` is written, "" for none; `None` if those tokens are not an
/// addressee.
fn addressee(tokens: Range<usize>, text: &TokenizedText) -> Option<String> {
    if tokens.is_empty() {
        return Some(String::new());
    }
    if let Some(group) = group(tokens.clone(), text) {
        return Some(group.to_owned());
    }
    if !tokens.clone().all(|index| is_name(text.token(index))) {
        return None;
    }
    Some(
        tokens
            .map(|index| capitalizing_first_word(&core(text.token(index))))
            .collect::<Vec<_>>()
            .join(" "),
    )
}

/// How the group named by the words of `tokens` is written, if they name one.
fn group(tokens: Range<usize>, text: &TokenizedText) -> Option<&'static str> {
    let name = words(tokens, text).join(" ");
    GROUPS
        .iter()
        .find(|(spoken, _)| s::canonically_equal(spoken, &name))
        .map(|&(_, written)| written)
}

fn is_group(tokens: Range<usize>, text: &TokenizedText) -> bool {
    group(tokens, text).is_some()
}

/// A capitalised word that is not a common word starting a sentence.
fn is_name(token: &str) -> bool {
    let core = core(token);
    let Some(first) = s::first_character(&core) else {
        return false;
    };
    if !s::is_uppercase(first) || s::contains_character(token, placeholder_token::OPENING) {
        return false;
    }
    !is_word_in(&edit_distance::normalize(&core), NOT_NAMES)
}

// MARK: - Sign-off

/// The sign-off and its signature, and the sign-off's first token.
fn sign_off(body_start: usize, text: &TokenizedText, list_markers: &[String]) -> Option<Part> {
    let mut best: Option<Part> = None;
    for (phrases, is_everyday) in [(SIGN_OFFS, false), (EVERYDAY_SIGN_OFFS, true)] {
        for phrase in phrases {
            for position in 0..text.words().len() {
                if !phrase_grammar::matches(phrase, position, text) {
                    continue;
                }
                let start = text.words()[position].token;
                let end = text.words()[position + phrase.len() - 1].token;
                if start <= body_start || !phrase_grammar::runs_on(position..position + phrase.len(), text) {
                    continue;
                }
                let Some(signature) = signature(end + 1, text) else {
                    continue;
                };
                if is_everyday && signature.is_empty() && !reads_as_a_letter(text, body_start, start, list_markers) {
                    continue;
                }
                if best.as_ref().is_some_and(|current| current.token <= start) {
                    continue;
                }
                let closing = capitalizing_first_word(&phrase.join(" ")) + ",";
                let text = if signature.is_empty() {
                    closing
                } else {
                    format!("{closing}\n{signature}")
                };
                best = Some(Part { text, token: start });
            }
        }
    }
    best
}

/// The name that runs from token `start` to the end of the text, "" when the sign-off ends the
/// text; `None` when what follows is not a name.
fn signature(start: usize, text: &TokenizedText) -> Option<String> {
    let token_count = text.tokens().len();
    let count = token_count - start;
    if count > LONGEST_SIGNATURE {
        return None;
    }
    let mut parts = Vec::new();
    for index in start..token_count {
        let token = text.token(index);
        let is_last = index == token_count - 1;
        let is_placeholder = s::contains_character(token, placeholder_token::OPENING);
        if !(is_placeholder || s::first_character(&core(token)).is_some_and(s::is_uppercase)) {
            return None;
        }
        let trailing = token_edges::trailing(token);
        if !is_last && !trailing.is_empty() && !is_initial(token) {
            return None;
        }
        parts.push(if is_last && !is_placeholder {
            s::drop_last(token, s::character_count(trailing))
        } else {
            token
        });
    }
    Some(parts.join(" "))
}

/// Whether the body's tokens from `start` up to `end` read as a letter's rather than a chat
/// message's: at least [`MINIMUM_LETTER_SENTENCES`] sentences, or a spoken list, numbered in
/// words ("first, …", "one is …") or with markers (two of `list_markers`).
fn reads_as_a_letter(text: &TokenizedText, start: usize, end: usize, list_markers: &[String]) -> bool {
    if start >= end {
        return false;
    }
    let tokens: Vec<&str> = (start..end).map(|index| text.token(index)).collect();
    let markers = tokens
        .iter()
        .filter(|token| list_markers.iter().any(|marker| s::contains_string(token, marker)))
        .count();
    let sentences = tokens
        .iter()
        .filter(|token| s::last_character(token).is_some_and(|last| s::is_one_of(last, &SENTENCE_ENDERS)))
        .count();
    markers >= 2 || sentences >= MINIMUM_LETTER_SENTENCES || ListFormatter::default().lines(&tokens.join(" ")).is_some()
}

/// "J." in "Sam J. Lee".
fn is_initial(token: &str) -> bool {
    s::character_count(token) == 2
        && s::first_character(token).is_some_and(s::is_uppercase)
        && s::last_character(token).is_some_and(|last| s::canonically_equal(last, "."))
}

// MARK: - Words

fn words<'t>(tokens: Range<usize>, text: &'t TokenizedText) -> Vec<&'t str> {
    text.words()
        .iter()
        .filter(|word| tokens.contains(&word.token))
        .map(|word| word.text.as_str())
        .collect()
}

/// The token without its leading and trailing punctuation.
fn core(token: &str) -> String {
    let leading = s::character_count(token_edges::leading(token));
    let trailing = s::character_count(token_edges::trailing(token));
    s::drop_last(s::drop_first(token, leading), trailing).to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frames_a_letter() {
        let frame = LetterFrame.frame(
            "Dear sir oh madam I am writing about my passport. Kind regards Jordan Lee",
            &[],
        );
        assert_eq!(
            frame,
            Some(TextFrame {
                opening: "Dear Sir or Madam,\n\n".into(),
                body: "I am writing about my passport.".into(),
                closing: "\n\nKind regards,\nJordan Lee".into(),
            })
        );
        assert_eq!(LetterFrame.frame("Hi John, can you send the report? Thanks", &[]), None);
    }
}
