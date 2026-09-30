//! Deep's output check, as the Mac app's `SelfRepair` (Cleanup/SelfRepair.swift), with its search
//! in [`alignment`] and the corrections it may resolve in [`corrections`].

mod alignment;
mod corrections;
#[cfg(test)]
mod tests;

use lt_shared::swift_string::{self as s};

use crate::GuardPolicy;
use crate::word_forms;
use crate::words::{WordSet, normalized_words, same};
use alignment::Alignment;

/// Longest correction phrase after a cue, and the stretch in which a garbled one may be repaired.
const CORRECTION_PHRASE_WORDS: usize = 6;
/// Most words a repair may add to or change in one correction phrase.
const MAX_REPAIR_WORDS: usize = 2;
/// Fewest items in a bulleted list the model makes: two things said in a sentence ("the invoice and
/// the agreement") stay in it. A numbered list may have two, as when they were counted.
pub(crate) const MIN_BULLETED_ITEMS: usize = 3;

/// Checks Deep's output: that it can be made from the text the model was given by the edits a
/// repair may make, and by no others.
///
/// Deep reads the whole dictation, so it may resolve a correction that reaches back into an
/// earlier sentence, read a garbled correction phrase as meant, fix grammar and misheard words, and
/// lay the text out. The limits the other levels use (length, similarity, a dropped cue checked by
/// `SelfCorrection`) would reject much of that, and widening them would let through what they
/// guard against. Instead the output is lined up with what was said, word by word, and every
/// difference must be one of these edits:
/// - a word kept, respelled, or put in another form of itself ("check" → "checked", "is" → "are",
///   "their" → "there"); two words merged or one split ("do not" → "don't", "twenty five" → "25").
///   A name is kept as said, and no word is respelled into one;
/// - a filler, a repeated word, or a word that only holds the grammar together dropped or added
///   ("I going" → "I am going");
/// - a self-correction resolved ([`corrections`]): as at Medium, up to
///   [`GuardPolicy::max_retracted_words`] words and the cue after them taken out, with "not" and
///   the words taken back when the speaker says them again ("four, no, not four, five"); from a
///   later sentence, a short correction phrase about the same thing (a word they share, or both a
///   number, a day, a month or a name) put in place of what it corrects, with the rest of the
///   earlier sentence kept. One may not answer a question: "Is it tomorrow? No, the day after."
///   keeps its "No". A cue's words are taken out only with the correction they make, and never
///   changed ("make that" is not "made that"). Nor may a correction that opens a later sentence
///   be dropped whole, leaving what it corrects as said;
/// - inside a correction phrase, up to [`MAX_REPAIR_WORDS`] new words or changed words, and the
///   words it corrects, which is how a garbled phrase is read as meant ("tomorrow. No, sorry, the
///   after tomorrow" → "the day after tomorrow");
/// - a list's numbers or bullets put in place of the words said to mark its items.
///
/// The layout is checked too (`OutputGuard`): a bulleted list has at least [`MIN_BULLETED_ITEMS`]
/// items, since two things said in a sentence stay in it, and no line holds only placeholders, as
/// when an emoji is moved below the sentence it ended.
///
/// Names, numbers, negations and words of time are kept as said everywhere else: none may be
/// added, dropped or changed, and no other new word may appear, so the model can't add a claim
/// ("he didn't" → "he didn't answer") or turn "after" into "before".
#[derive(Clone, Debug)]
pub(crate) struct SelfRepair {
    cues: Vec<Vec<String>>,
    cue_words: WordSet,
    fillers: WordSet,
    negations: WordSet,
    function_words: WordSet,
    max_retracted_words: usize,
    min_respelling_similarity: f64,
}

impl SelfRepair {
    pub(crate) fn new(policy: &GuardPolicy) -> Self {
        // "Or rather" is one cue at Deep: its "or" goes with it.
        let cues = policy
            .correction_cues
            .iter()
            .map(String::as_str)
            .chain(["or rather"])
            .map(normalized_words)
            .filter(|cue| !cue.is_empty())
            .collect();
        let cue_words = policy
            .correction_cues
            .iter()
            .map(|cue| normalized_words(cue))
            .filter(|words| words.len() == 1)
            .flatten();
        Self {
            cues,
            cue_words: WordSet::new(cue_words),
            fillers: WordSet::normalized(&policy.fillers),
            negations: WordSet::normalized(&policy.negations),
            function_words: WordSet::normalized(&policy.function_words),
            max_retracted_words: policy.max_retracted_words,
            min_respelling_similarity: policy.min_respelling_similarity,
        }
    }

    /// Whether `cleaned` can be made from `raw` by a repair's edits. `placeholders` are the
    /// normalised placeholder tokens, which must come through as they are.
    pub(crate) fn accepts(&self, raw: &str, cleaned: &str, placeholders: &WordSet) -> bool {
        let said = self.words_said(raw, placeholders);
        let written = written_words(cleaned);
        if said.is_empty() {
            return written.is_empty();
        }
        let spoken = WordSet::new(said.iter().map(|word| &word.word));
        let aligns =
            |candidate: &[SaidWord]| Alignment::new(self, candidate, &written, placeholders, &spoken).reaches_end();
        // Re-using the words it corrects, a repaired phrase could come out as those words.
        if corrections::dropped(&said, self)
            .iter()
            .any(|candidate| aligns(candidate))
        {
            return false;
        }
        aligns(&said)
            || self
                .rewrites(&said, placeholders)
                .iter()
                .any(|candidate| aligns(candidate))
    }

    /// The words of `raw` as said ([`said_words`]), with every word of every correction cue
    /// marked.
    pub(crate) fn words_said(&self, raw: &str, placeholders: &WordSet) -> Vec<SaidWord> {
        let mut said = said_words(raw, &self.function_words, placeholders);
        for cue in &self.cues {
            for start in occurrences(cue, &said) {
                for word in &mut said[start..start + cue.len()] {
                    word.is_cue = true;
                }
            }
        }
        said
    }

    /// `said` with the corrections whose phrase goes back applied, in every way they may be
    /// ([`corrections::applied`]).
    pub(crate) fn rewrites(&self, said: &[SaidWord], placeholders: &WordSet) -> Vec<Vec<SaidWord>> {
        corrections::applied(said, self, placeholders)
    }

    // MARK: - Word classes

    /// A word no repair may add, drop or change outside a correction: a negation, a number or a
    /// word of time, or a placeholder.
    fn is_protected(&self, word: &str, placeholders: &WordSet) -> bool {
        self.is_negation(word)
            || word_forms::is_number(word)
            || word_forms::is_unit_word(word)
            || word_forms::is_time_word(word)
            || placeholders.contains(word)
    }

    fn is_filler(&self, word: &str) -> bool {
        self.fillers.contains(word)
    }

    fn is_negation(&self, word: &str) -> bool {
        self.negations.contains(word) || is_negated_verb(word)
    }

    /// A one-word correction cue ("sorry", "no", "actually").
    fn is_cue(&self, word: &str) -> bool {
        self.cue_words.contains(word)
    }

    /// Cues that take back everything before them ("scratch that"), not one thing for another, so
    /// what they retract need not be replaced fact for fact.
    fn retracts_statement(words: &[SaidWord]) -> bool {
        matches!(words, [first, second, ..] if same(&first.word, "scratch") && same(&second.word, "that"))
    }

    fn is_function_word(&self, word: &str) -> bool {
        self.function_words.contains(word)
    }
}

/// A verb with its negation in it: "don't", "isn't", "cannot".
fn is_negated_verb(word: &str) -> bool {
    s::has_suffix(word, "n't") || same(word, "cannot")
}

/// Start indices of each occurrence of the words of `cue` in `words`.
fn occurrences(cue: &[String], words: &[SaidWord]) -> Vec<usize> {
    if words.len() < cue.len() {
        return Vec::new();
    }
    (0..=words.len() - cue.len())
        .filter(|&start| {
            words[start..start + cue.len()]
                .iter()
                .zip(cue)
                .all(|(word, cue_word)| same(&word.word, cue_word))
        })
        .collect()
}

// MARK: - Words

/// A word as said, with what its punctuation and capital say about it.
#[derive(Clone, Debug, Default)]
pub(crate) struct SaidWord {
    pub(crate) word: String,
    pub(crate) ends_sentence: bool,
    pub(crate) ends_question: bool,
    pub(crate) is_name: bool,
    /// Capitalised where no sentence starts, as a name or the month "May" is.
    pub(crate) is_capitalised: bool,
    /// A name, or a capitalised word that starts a sentence and could be one ("Chloe will …").
    pub(crate) may_be_name: bool,
    /// Where a correction from a later sentence was put in place of what it corrects, how many
    /// words its phrase has, starting here; 0 elsewhere (see [`corrections`]).
    pub(crate) opens_phrase: usize,
    /// The words that correction corrected, which a repair of its phrase may re-use.
    pub(crate) spare: Vec<String>,
    /// Part of a correction cue ("scratch that", "no"), which only a correction may take out.
    pub(crate) is_cue: bool,
}

/// Equal as Swift's synthesized `==` finds them: words compared by canonical equivalence.
impl PartialEq for SaidWord {
    fn eq(&self, other: &Self) -> bool {
        same(&self.word, &other.word)
            && self.ends_sentence == other.ends_sentence
            && self.ends_question == other.ends_question
            && self.is_name == other.is_name
            && self.is_capitalised == other.is_capitalised
            && self.may_be_name == other.may_be_name
            && self.opens_phrase == other.opens_phrase
            && self.spare.len() == other.spare.len()
            && self.spare.iter().zip(&other.spare).all(|(a, b)| same(a, b))
            && self.is_cue == other.is_cue
    }
}

/// A word as written, with what its capital and line say about it. (The Mac app's also keeps the
/// text the word came from, which nothing reads.)
#[derive(Clone, Debug)]
pub(crate) struct WrittenWord {
    pub(crate) word: String,
    pub(crate) is_capitalised: bool,
    pub(crate) starts_sentence: bool,
    /// The first word of a list item whose number or bullet was taken off.
    pub(crate) starts_list_item: bool,
}

const SENTENCE_ENDERS: [&str; 4] = [".", "!", "?", "…"];
const HYPHENS: [&str; 3] = ["-", "\u{2014}", "\u{2013}"];
const BULLETS: [&str; 9] = ["-", "*", "•", "‣", "◦", "▪", "–", "—", "·"];

/// The words of `text` as [`normalized_words`] finds them, each with whether it ends a sentence
/// (or a line) or a question, and whether it is a name: capitalised where no sentence starts, and
/// not a function word (as `SpokenNames` decides).
pub(crate) fn said_words(text: &str, function_words: &WordSet, placeholders: &WordSet) -> Vec<SaidWord> {
    let mut words: Vec<SaidWord> = Vec::new();
    for line in s::split_where(text, usize::MAX, true, s::is_newline) {
        let mut starts_sentence = true;
        let line_start = words.len();
        for part in parts(line) {
            let trailing = trailing_marks(part);
            let ends = trailing.iter().any(|mark| s::is_one_of(mark, &SENTENCE_ENDERS));
            let asks = trailing.iter().any(|mark| s::canonically_equal(mark, "?"));
            let normalized = normalized_words(part);
            if normalized.is_empty()
                && ends
                && words.len() > line_start
                && let Some(last) = words.last_mut()
            {
                last.ends_sentence = true;
                last.ends_question = asks;
            }
            let upper = starts_with_uppercase(part);
            let count = normalized.len();
            for (offset, word) in normalized.into_iter().enumerate() {
                let is_last_of_part = offset == count - 1;
                let upper = offset == 0 && upper;
                let could_be_name = upper && !function_words.contains(&word) && !placeholders.contains(&word);
                words.push(SaidWord {
                    word,
                    ends_sentence: is_last_of_part && ends,
                    ends_question: is_last_of_part && asks,
                    is_name: could_be_name && !starts_sentence,
                    is_capitalised: upper && !starts_sentence,
                    may_be_name: could_be_name,
                    ..SaidWord::default()
                });
            }
            if count > 0 {
                starts_sentence = ends;
            }
        }
        if words.len() > line_start
            && let Some(last) = words.last_mut()
            && !last.ends_sentence
        {
            last.ends_sentence = true;
            last.ends_question = false;
        }
    }
    words
}

/// The words of `text`, with the numbers and bullets that start its list items taken off.
pub(crate) fn written_words(text: &str) -> Vec<WrittenWord> {
    let mut words = Vec::new();
    for line in s::split_where(text, usize::MAX, true, s::is_newline) {
        let (item, is_list_item) = without_list_marker(line);
        let mut starts_sentence = true;
        let mut first_of_line = true;
        for part in parts(item) {
            let normalized = normalized_words(part);
            let upper = starts_with_uppercase(part);
            let count = normalized.len();
            for (offset, word) in normalized.into_iter().enumerate() {
                words.push(WrittenWord {
                    word,
                    is_capitalised: offset == 0 && upper,
                    starts_sentence,
                    starts_list_item: is_list_item && first_of_line,
                });
                first_of_line = false;
            }
            if count > 0 {
                starts_sentence = trailing_marks(part)
                    .iter()
                    .any(|mark| s::is_one_of(mark, &SENTENCE_ENDERS))
                    || s::has_suffix(part, ":");
            }
        }
    }
    words
}

/// `line` without a leading bullet ("-", "•", "*") or item number ("1.", "2)"), and whether it had
/// one.
pub(crate) fn without_list_marker(line: &str) -> (&str, bool) {
    let trimmed = s::drop_while(line, s::is_whitespace);
    let followed_by_space = |rest: &str| s::first_character(rest).is_some_and(s::is_whitespace);
    if is_bulleted(line)
        && let Some(first) = s::first_character(trimmed)
    {
        return (&trimmed[first.len()..], true);
    }
    let digits = s::prefix_while(trimmed, s::is_number);
    let after_digits = &trimmed[digits.len()..];
    if (1..=3).contains(&s::character_count(digits))
        && let Some(mark) = s::first_character(after_digits)
        && (s::canonically_equal(mark, ".") || s::canonically_equal(mark, ")"))
        && followed_by_space(&after_digits[mark.len()..])
    {
        return (&after_digits[mark.len()..], true);
    }
    (line, false)
}

/// Whether `line` starts with a bullet and a space.
fn is_bulleted(line: &str) -> bool {
    let trimmed = s::drop_while(line, s::is_whitespace);
    s::first_character(trimmed).is_some_and(|first| {
        s::is_one_of(first, &BULLETS) && s::first_character(&trimmed[first.len()..]).is_some_and(s::is_whitespace)
    })
}

/// How many items each bulleted list in `text` has: a list is a run of lines that start with a
/// bullet, which a blank line or any other line ends.
pub(crate) fn bulleted_list_lengths(text: &str) -> Vec<usize> {
    let mut lengths = Vec::new();
    let mut run = 0;
    for line in s::split_where(text, usize::MAX, false, s::is_newline) {
        if is_bulleted(line) {
            run += 1;
        } else if run > 0 {
            lengths.push(run);
            run = 0;
        }
    }
    if run > 0 {
        lengths.push(run);
    }
    lengths
}

/// How many lines of `text` hold placeholders and nothing else, list markers and punctuation aside.
/// `placeholders` are normalized, as the words are.
pub(crate) fn placeholder_line_count(text: &str, placeholders: &WordSet) -> usize {
    if placeholders.is_empty() {
        return 0;
    }
    s::split_where(text, usize::MAX, true, s::is_newline)
        .into_iter()
        .filter(|line| {
            let words = normalized_words(without_list_marker(line).0);
            !words.is_empty() && words.iter().all(|word| placeholders.contains(word))
        })
        .count()
}

/// The runs of `line` between whitespace, each split at hyphens and dashes, as the words said
/// and written are read.
fn parts(line: &str) -> impl Iterator<Item = &str> {
    s::split_whitespace(line)
        .into_iter()
        .flat_map(|token| s::split_where(token, usize::MAX, true, |character| s::is_one_of(character, &HYPHENS)))
}

/// The characters after the last letter or number of `part`, last first.
fn trailing_marks(part: &str) -> Vec<&str> {
    s::characters(part)
        .rev()
        .take_while(|&character| !s::is_letter(character) && !s::is_number(character))
        .collect()
}

/// Whether the first letter of `part` is a capital.
fn starts_with_uppercase(part: &str) -> bool {
    s::characters(part)
        .find(|&character| s::is_letter(character))
        .is_some_and(s::is_uppercase)
}

/// Words from `start` to the end of its sentence, inclusive; 0 past the end.
fn phrase_length(start: usize, words: &[SaidWord]) -> usize {
    if start >= words.len() {
        return 0;
    }
    let end = words[start..]
        .iter()
        .position(|word| word.ends_sentence)
        .map_or(words.len() - 1, |offset| start + offset);
    end - start + 1
}
