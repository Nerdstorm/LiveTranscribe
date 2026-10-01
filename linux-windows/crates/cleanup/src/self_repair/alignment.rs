//! The search behind [`SelfRepair::accepts`], as the Mac app's `SelfRepair.Alignment`
//! (Cleanup/SelfRepairAlignment.swift).

use lt_shared::edit_distance;
use lt_shared::swift_string::{self as s};

use super::{CORRECTION_PHRASE_WORDS, MAX_REPAIR_WORDS, SaidWord, SelfRepair, WrittenWord};
use super::{corrections, is_negated_verb, phrase_length};
use crate::word_forms;
use crate::words::{WordSet, same};

const PHRASE: usize = CORRECTION_PHRASE_WORDS;
const REPAIRS: usize = MAX_REPAIR_WORDS;

/// The highest state, which the bit sets must hold.
const LAST_STATE: usize = encode(PHRASE, REPAIRS, true);
const _: () = assert!(
    LAST_STATE < u64::BITS as usize,
    "the search's states must fit its bit sets"
);

/// An edit the search can make: how many said and written words it takes, and the state after it.
type Step = (usize, usize, usize);

/// Most letters spelled out that may be written as one word.
const MAX_ACRONYM_LETTERS: usize = 6;

/// Whether some sequence of a repair's edits turns the words said into the words written.
///
/// Positions are pairs of said and written word indices, visited in order. At each, the search
/// also knows whether it is inside a correction phrase, how much of that phrase is left, how many
/// repairs it still allows, and whether a word of it has been written; that state fits in a bit
/// set, so the search takes time proportional to the two lengths multiplied. A phrase follows a
/// cue within a sentence, or opens where a correction from a later sentence was put
/// ([`corrections`]). Once a word of a phrase has been written, the words it corrected may be
/// written too ("three servers, sorry, four" → "four servers"; "next week, sorry, the after next"
/// → "the week after next"), until the word after the phrase is read; never before, which would
/// keep what was taken back and drop only the cue.
pub(super) struct Alignment<'a> {
    repair: &'a SelfRepair,
    said: &'a [SaidWord],
    written: &'a [WrittenWord],
    placeholders: &'a WordSet,
    /// Every word of the dictation as said, before any correction was applied.
    spoken: &'a WordSet,
    /// For each said index, where the self-corrections that may be taken out from it end.
    spans: Vec<Vec<usize>>,
    /// For each said index, the corrected words a repair may write there: in the correction phrase
    /// that covers it, or just after, before the next said word is read.
    spare: Vec<WordSet>,
    /// For each said index, the words corrected by the phrase that covers it, which a repair may
    /// not add there as new words.
    corrected: Vec<WordSet>,
    /// The words of the cues said, whose forms a repair may not add ("make that" → "made that").
    cue_words: Vec<String>,
}

impl<'a> Alignment<'a> {
    pub(super) fn new(
        repair: &'a SelfRepair,
        said: &'a [SaidWord],
        written: &'a [WrittenWord],
        placeholders: &'a WordSet,
        spoken: &'a WordSet,
    ) -> Self {
        let corrections = corrections::spans(said, repair, placeholders);
        let n = said.len();
        let mut spare = vec![WordSet::default(); n + 1];
        let mut corrected = vec![WordSet::default(); n + 1];
        let cover = |sets: &mut [WordSet], start: usize, length: usize, words: &WordSet| {
            for set in &mut sets[start..=(start + length).min(n)] {
                set.form_union(words);
            }
        };
        for (start, words) in corrections.spare.iter().enumerate() {
            cover(&mut spare, start, phrase_length(start, said).min(PHRASE), words);
        }
        for (start, words) in corrections.corrected.iter().enumerate() {
            cover(&mut corrected, start, phrase_length(start, said).min(PHRASE), words);
        }
        for (start, word) in said.iter().enumerate().filter(|(_, word)| word.opens_phrase > 0) {
            let words = WordSet::new(&word.spare);
            cover(&mut spare, start, word.opens_phrase, &words);
            cover(&mut corrected, start, word.opens_phrase, &words);
        }
        Self {
            repair,
            said,
            written,
            placeholders,
            spoken,
            spans: corrections.ends,
            spare,
            corrected,
            cue_words: said
                .iter()
                .filter(|word| word.is_cue)
                .map(|word| word.word.clone())
                .collect(),
        }
    }

    pub(super) fn reaches_end(&self) -> bool {
        let (n, m) = (self.said.len(), self.written.len());
        let at = |i: usize, j: usize| i * (m + 1) + j;
        let mut reached = vec![0_u64; (n + 1) * (m + 1)];
        reached[0] = 1;
        for i in 0..=n {
            for j in 0..=m {
                // Opening a phrase moves to another state at the same position, so states are
                // visited until none is new.
                let mut visited = 0_u64;
                loop {
                    let pending = reached[at(i, j)] & !visited;
                    if pending == 0 {
                        break;
                    }
                    for state in (0..=LAST_STATE).filter(|state| pending & (1 << state) != 0) {
                        visited |= 1 << state;
                        for (di, dj, next) in self.steps(i, j, state) {
                            reached[at(i + di, j + dj)] |= 1 << next;
                        }
                    }
                }
            }
        }
        reached[at(n, m)] != 0
    }

    // MARK: - Steps

    /// Every edit that can be made at said index `i` and written index `j`.
    fn steps(&self, i: usize, j: usize, state: usize) -> Vec<Step> {
        let (n, m) = (self.said.len(), self.written.len());
        let mut steps = Vec::new();
        if i < n && state == 0 && self.said[i].opens_phrase > 0 {
            steps.push((0, 0, encode(self.said[i].opens_phrase.min(PHRASE), REPAIRS, false)));
        }
        if i < n && j < m && self.keeps(&self.said[i], &self.written[j]) {
            steps.push((1, 1, self.consuming(1, i, state, true)));
        }
        if i < n && self.is_droppable(i, j) {
            steps.push((1, 0, self.consuming(1, i, state, false)));
        }
        if let Some(ends) = self.spans.get(i) {
            steps.extend(ends.iter().map(|&end| (end - i, 0, self.opening(end))));
        }
        if j < m && word_forms::is_insertable(&self.written[j].word) {
            steps.push((0, 1, state));
        }
        if state != 0 && j < m {
            let (left, repairs_left, begun) = decode(state);
            let word = &self.written[j].word;
            let new = self.is_repair(&self.written[j]) && !self.corrected[i].contains(word);
            if begun && self.spare[i].contains(word) && !self.placeholders.contains(word) {
                steps.push((0, 1, state));
            } else if left > 0 && repairs_left > 0 && new {
                steps.push((0, 1, encode(left, repairs_left - 1, begun)));
            }
            if left > 0 && repairs_left > 0 && i < n && self.is_replaceable(&self.said[i]) && new {
                let after = self.consuming(1, i, encode(left, repairs_left - 1, begun), true);
                steps.push((1, 1, after));
            }
        }
        if i + 1 < n && j < m && self.merges(&self.said[i], &self.said[i + 1], &self.written[j]) {
            steps.push((2, 1, self.consuming(2, i, state, true)));
        }
        if i < n && j + 1 < m && self.splits(&self.said[i], &self.written[j], &self.written[j + 1]) {
            steps.push((1, 2, self.consuming(1, i, state, true)));
        }
        self.number_steps(i, j, state, &mut steps);
        if let Some(step) = self.acronym_step(i, j, state) {
            steps.push(step);
        }
        steps
    }

    /// Letters spelled out and written as one word, in order ("p r" → "PR", "A P I" → "API"): two
    /// to [`MAX_ACRONYM_LETTERS`] said words of one letter each. Speech-to-text gives them
    /// capitals, as it does names, so a spelled letter is kept as a letter either way.
    fn acronym_step(&self, i: usize, j: usize, state: usize) -> Option<Step> {
        let letters = self.written.get(j)?.word.as_str();
        let count = s::character_count(letters);
        if !(2..=MAX_ACRONYM_LETTERS).contains(&count)
            || i + count > self.said.len()
            || !s::characters(letters).all(s::is_letter)
        {
            return None;
        }
        let run = &self.said[i..i + count];
        let spelled = run
            .iter()
            .all(|word| s::character_count(&word.word) == 1 && !word.is_cue);
        if !spelled || run[..count - 1].iter().any(|word| word.ends_sentence) {
            return None;
        }
        let joined: String = run.iter().map(|word| word.word.as_str()).collect();
        same(&joined, letters).then(|| (count, 1, self.consuming(count, i, state, true)))
    }

    /// A number said in words and written in digits, or the other way round ("twenty five" →
    /// "25", "2:30" → "two thirty"), with the same value.
    fn number_steps(&self, i: usize, j: usize, state: usize, steps: &mut Vec<Step>) {
        let (n, m) = (self.said.len(), self.written.len());
        if i >= n || j >= m {
            return;
        }
        if let Some(written_value) = word_forms::value(&[&self.written[j].word]) {
            let mut k = 0;
            while i + k < n && k < 5 && word_forms::is_number_word(&self.said[i + k].word) {
                k += 1;
                if k > 1 && word_forms::value(&words_of(&self.said[i..i + k])).as_ref() == Some(&written_value) {
                    steps.push((k, 1, self.consuming(k, i, state, true)));
                }
            }
        }
        if let Some(said_value) = word_forms::value(&[&self.said[i].word]) {
            let mut l = 0;
            while j + l < m && l < 5 && word_forms::is_number_word(&self.written[j + l].word) {
                l += 1;
                let written: Vec<&str> = self.written[j..j + l].iter().map(|word| word.word.as_str()).collect();
                if l > 1 && word_forms::value(&written).as_ref() == Some(&said_value) {
                    steps.push((1, l, self.consuming(1, i, state, true)));
                }
            }
        }
    }

    // MARK: - Edits

    /// Whether `written_word` keeps `said_word`: the same word or another form of it, a word
    /// speech-to-text confuses with it ("weather", "whether"), or a respelling; a protected word
    /// only as itself, as another way of writing its number, or, for a negated verb, in another
    /// form that keeps its negation ("don't" → "doesn't"); a cue only as itself. A respelling is
    /// never a filler, nor a name the speaker didn't say: a word written with a capital where no
    /// sentence starts is a name, which keeps only itself or takes its possessive ("uma" is not
    /// "Una", "jura" not "Jira", "Kirk" not "Kurt"), and one that starts a sentence may be, so only
    /// another form is written there ("uma hasn't" is not "Una hasn't"). Where a list item starts,
    /// the capital is the layout's, so a word said within a sentence is respelled there as anywhere
    /// else. A capital a word had as said shows only that speech-to-text took it for a name, which
    /// a misheard word often isn't: "can you Madge it" may be "can you merge it", and "First, Madge
    /// the PR" "1. Merge the PR".
    fn keeps(&self, said_word: &SaidWord, written_word: &WrittenWord) -> bool {
        let (said, word) = (said_word.word.as_str(), written_word.word.as_str());
        if same(said, word) {
            return true;
        }
        if said_word.is_cue || self.repair.is_filler(word) {
            return false;
        }
        if self.repair.is_protected(said, self.placeholders) || self.repair.is_protected(word, self.placeholders) {
            if let Some(value) = word_forms::value(&[said])
                && word_forms::value(&[word]).as_ref() == Some(&value)
            {
                return true;
            }
            return is_negated_verb(said) && is_negated_verb(word) && word_forms::are_forms(said, word);
        }
        let pronoun = same(word, "i") || s::has_prefix(word, "i'");
        let laid_out = written_word.starts_list_item && !said_word.starts_sentence;
        let may_be_name = written_word.is_capitalised && !pronoun && !laid_out;
        if may_be_name && !written_word.starts_sentence {
            return !self.spoken.contains(word) && possessives(said).iter().any(|possessive| same(possessive, word));
        }
        if word_forms::are_forms(said, word) {
            return true;
        }
        !may_be_name
            && !self.repair.is_cue(word)
            && !self.spoken.contains(word)
            && edit_distance::normalized_similarity(said, word) >= self.repair.min_respelling_similarity
    }

    /// A filler, a word said twice in a row, a word that only holds the grammar together, a unit
    /// whose number is now written with its symbol ("dollars" in "twenty five dollars" → "$25"),
    /// or a word said to mark the list item that is written next.
    fn is_droppable(&self, i: usize, j: usize) -> bool {
        let said = &self.said[i];
        let word = said.word.as_str();
        if self.repair.is_filler(word) {
            return true;
        }
        let said_again = |index: usize| self.said.get(index).is_some_and(|other| same(&other.word, word));
        if said_again(i + 1) || (i > 0 && said_again(i - 1)) {
            return true;
        }
        if self.written.get(j).is_some_and(|next| next.starts_list_item) && self.is_list_marker(i) {
            return true;
        }
        if word_forms::is_unit_word(word) && i > 0 && word_forms::is_number(&self.said[i - 1].word) {
            return true;
        }
        if said.is_cue || said.is_name || self.repair.is_protected(word, self.placeholders) {
            return false;
        }
        word_forms::is_droppable(word)
    }

    fn is_list_marker(&self, i: usize) -> bool {
        let word = &self.said[i].word;
        word_forms::is_list_marker(word)
            || (word_forms::is_number_word(word) && i > 0 && same(&self.said[i - 1].word, "number"))
    }

    /// A word a repair may add or put in place of another inside a correction phrase: not a
    /// protected word, a name, a cue or a filler.
    fn is_repair(&self, word: &WrittenWord) -> bool {
        let text = word.word.as_str();
        // A capital shows a name, except at the start of a sentence, where only a word that holds
        // the grammar together is surely not one.
        let may_be_name = word.is_capitalised && (!word.starts_sentence || !self.repair.is_function_word(text));
        !self.repair.is_protected(text, self.placeholders)
            && !may_be_name
            && !self.repair.is_cue(text)
            && !self.repair.is_filler(text)
            && !self
                .cue_words
                .iter()
                .any(|cue| same(cue, text) || word_forms::are_forms(cue, text))
    }

    fn is_replaceable(&self, word: &SaidWord) -> bool {
        !self.repair.is_protected(&word.word, self.placeholders) && !word.is_name && !word.is_cue
    }

    /// Two words said as one written: a contraction, the two run together, or a respelling of both;
    /// never across the end of a sentence ("plan A. I think" is not "plan AI think").
    fn merges(&self, first: &SaidWord, second: &SaidWord, written: &WrittenWord) -> bool {
        if first.is_cue || second.is_cue || first.is_name || second.is_name || first.ends_sentence {
            return false;
        }
        let (a, b, word) = (first.word.as_str(), second.word.as_str(), written.word.as_str());
        let joined = format!("{a}{b}");
        if contracts(word, a, b) || same(&joined, word) {
            return true;
        }
        let protected = [a, b, word]
            .into_iter()
            .any(|word| self.repair.is_protected(word, self.placeholders));
        !protected && !self.spoken.contains(word) && edit_distance::normalized_similarity(&joined, word) >= 0.8
    }

    fn splits(&self, said: &SaidWord, first: &WrittenWord, second: &WrittenWord) -> bool {
        if said.is_cue || said.is_name {
            return false;
        }
        contracts(&said.word, &first.word, &second.word) || same(&format!("{}{}", first.word, second.word), &said.word)
    }

    // MARK: - Correction phrases

    /// The state after taking `count` said words from `i`, `writing` something for them or
    /// dropping them: a correction phrase is read once its sentence ends or its words run out, and
    /// left with the next said word.
    fn consuming(&self, count: usize, i: usize, state: usize, writing: bool) -> usize {
        if state == 0 {
            return 0;
        }
        let (left, repairs, begun) = decode(state);
        if left < count {
            return 0;
        }
        let end = (i + count).min(self.said.len());
        let ends_sentence = self.said[i..end].iter().any(|word| word.ends_sentence);
        encode(if ends_sentence { 0 } else { left - count }, repairs, begun || writing)
    }

    /// The state at the start of the correction phrase that begins at said index `start`.
    fn opening(&self, start: usize) -> usize {
        match phrase_length(start, self.said) {
            0 => 0,
            length => encode(length.min(PHRASE), REPAIRS, false),
        }
    }
}

/// State 0 is outside any correction phrase; the others are inside one, with `left` of its words
/// still to read (0 once it has been read), `repairs` still allowed, and whether a word of it has
/// been written (`begun`).
const fn encode(left: usize, repairs: usize, begun: bool) -> usize {
    1 + (left * (REPAIRS + 1) + repairs) * 2 + begun as usize
}

fn decode(state: usize) -> (usize, usize, bool) {
    let value = state - 1;
    (value / 2 / (REPAIRS + 1), value / 2 % (REPAIRS + 1), value % 2 == 1)
}

fn words_of(words: &[SaidWord]) -> Vec<&str> {
    words.iter().map(|word| word.word.as_str()).collect()
}

/// Whether `word` contracts `first` and `second` ("don't" → "do", "not").
fn contracts(word: &str, first: &str, second: &str) -> bool {
    word_forms::expansions(word)
        .iter()
        .any(|[a, b]| same(a, first) && same(b, second))
}

fn possessives(name: &str) -> [String; 2] {
    let plural = if s::has_suffix(name, "s") {
        format!("{name}'")
    } else {
        format!("{name}s'")
    };
    [format!("{name}'s"), plural]
}
