use std::collections::{BTreeMap, HashMap, HashSet};

use lt_shared::edit_distance;
use lt_shared::swift_string::{self as s};

use crate::word_tokenizer;

/// Finds the vocabulary terms a text nearly contains, scoring exactly as
/// [`edit_distance::normalized_similarity`] does, fast enough for a large vocabulary.
///
/// The obvious approach, a full edit distance between every term form and every word and word pair
/// of the text, took about 12 seconds (debug build) for a thousand terms against a 300-word
/// dictation, and grows with both. Three things make it cheap without changing any score:
/// - Characters are coded as small integers once, so comparing two is an integer comparison rather
///   than a grapheme-cluster comparison.
/// - Units are grouped by length, and a length is skipped when the difference alone rules it out:
///   the edit distance is at least the difference in length.
/// - The edit distance is computed only within the band of the largest distance that still reaches
///   the threshold, and abandoned as soon as a whole row exceeds it.
#[derive(Clone, Debug)]
pub(crate) struct TermSimilarity {
    /// A code for every character in any form. Characters seen only in a text get codes past these,
    /// which match nothing, as they should.
    alphabet: HashMap<String, usize>,
    /// Per term: its distinct forms (spelling and variants, normalised), as character codes.
    forms_by_term: Vec<Vec<Vec<usize>>>,
    threshold: f64,
}

impl TermSimilarity {
    /// `phrases_by_term` holds, per term, its spelling followed by its spoken variants.
    /// `threshold` is the lowest similarity that counts as nearly said.
    pub fn new(phrases_by_term: &[Vec<String>], threshold: f64) -> Self {
        let mut alphabet = HashMap::new();
        let mut forms_by_term = Vec::with_capacity(phrases_by_term.len());
        for phrases in phrases_by_term {
            let mut seen = HashSet::new();
            let mut forms = Vec::new();
            for form in phrases.iter().map(|phrase| edit_distance::normalize(phrase)) {
                if form.is_empty() || !seen.insert(s::canonical_key(&form).into_owned()) {
                    continue;
                }
                forms.push(encode(&form, &mut alphabet));
            }
            forms_by_term.push(forms);
        }
        Self {
            alphabet,
            forms_by_term,
            threshold,
        }
    }

    /// Indices of the terms whose best similarity to a word or adjacent word pair of `text` reaches
    /// the threshold, most similar first and ties in term order. Terms for which `is_excluded`
    /// returns true are not scored.
    pub fn similar_terms(&self, text: &str, is_excluded: impl Fn(usize) -> bool) -> Vec<usize> {
        let mut alphabet = self.alphabet.clone();
        // Keyed by length in characters, and so visited shortest first.
        let mut units_by_length: BTreeMap<usize, Vec<Vec<usize>>> = BTreeMap::new();
        for unit in units(text) {
            let codes = encode(&unit, &mut alphabet);
            units_by_length.entry(codes.len()).or_default().push(codes);
        }
        let Some(&longest_unit) = units_by_length.keys().next_back() else {
            return Vec::new();
        };
        let longest_form = self.forms_by_term.iter().flatten().map(Vec::len).max().unwrap_or(0);
        let limits: Vec<Option<usize>> = (0..=longest_unit.max(longest_form))
            .map(|longer| self.largest_distance(longer))
            .collect();

        let mut rows = bounded_edit_distance::Rows::default();
        let mut scored: Vec<(usize, f64)> = Vec::new();
        for (index, forms) in self.forms_by_term.iter().enumerate() {
            if is_excluded(index) {
                continue;
            }
            let mut best = f64::NEG_INFINITY;
            'search: for form in forms {
                for (&length, units) in &units_by_length {
                    let longer = form.len().max(length);
                    let Some(limit) = limits[longer] else { continue };
                    let gap = form.len().abs_diff(length);
                    // The gap is a lower bound on the distance, so this is the best score possible.
                    let may_improve = gap <= limit && score(gap, longer) > best;
                    if !may_improve {
                        continue;
                    }
                    for unit in units {
                        let Some(distance) = bounded_edit_distance::distance(form, unit, limit, &mut rows) else {
                            continue;
                        };
                        best = best.max(score(distance, longer));
                        if distance == 0 {
                            break 'search;
                        }
                    }
                }
            }
            if best >= self.threshold {
                scored.push((index, best));
            }
        }
        // Scores are never NaN, so this orders them as comparing with `>` would.
        scored.sort_by(|lhs, rhs| rhs.1.total_cmp(&lhs.1).then(lhs.0.cmp(&rhs.0)));
        scored.into_iter().map(|(index, _)| index).collect()
    }

    /// The largest edit distance between strings whose longer one has `longer` characters that
    /// still scores at least the threshold, or `None` when none does. Found with the same formula
    /// as the score, so the boundary is exactly where [`edit_distance`] puts it.
    fn largest_distance(&self, longer: usize) -> Option<usize> {
        (0..=longer)
            .rev()
            .find(|&distance| score(distance, longer) >= self.threshold)
    }
}

/// [`edit_distance::normalized_similarity`]'s formula.
fn score(distance: usize, longer: usize) -> f64 {
    1.0 - distance as f64 / longer as f64
}

/// The characters of `text` as codes, giving each character not yet in `alphabet` the next one.
/// Canonically equivalent characters share a code, as they are one `Character` to Swift.
fn encode(text: &str, alphabet: &mut HashMap<String, usize>) -> Vec<usize> {
    s::characters(text)
        .map(|character| {
            let key = s::canonical_key(character);
            if let Some(&code) = alphabet.get(key.as_ref()) {
                return code;
            }
            let code = alphabet.len();
            alphabet.insert(key.into_owned(), code);
            code
        })
        .collect()
}

/// The text's normalised words and adjacent word pairs, without repeats: a name misheard as two
/// words ("nerd storm" for "Nerdstorm") is only similar as a pair.
///
/// Words come from [`word_tokenizer`], the definition the replacer and the selector's first ranking
/// step use, so a placeholder ("⟦S1⟧") never counts as something said.
fn units(text: &str) -> Vec<String> {
    let words: Vec<String> = word_tokenizer::words(text)
        .iter()
        .flat_map(|word| {
            let normalized = edit_distance::normalize(&word.key);
            edit_distance::words(&normalized)
                .into_iter()
                .map(str::to_owned)
                .collect::<Vec<_>>()
        })
        .collect();
    let pairs = words.windows(2).map(|pair| format!("{} {}", pair[0], pair[1]));
    let mut seen = HashSet::new();
    words
        .iter()
        .cloned()
        .chain(pairs)
        .filter(|unit| seen.insert(s::canonical_key(unit).into_owned()))
        .collect()
}

/// Levenshtein distance that gives up past a limit (Ukkonen's banded algorithm).
///
/// Only cells within `limit` of the diagonal can hold a distance of `limit` or less, so each row
/// computes at most `2 * limit + 1` cells, and a row whose cells all exceed the limit ends the
/// computation.
mod bounded_edit_distance {
    /// Two rows reused across calls, so a search over many pairs allocates only as they grow.
    #[derive(Clone, Debug, Default)]
    pub(super) struct Rows {
        previous: Vec<usize>,
        current: Vec<usize>,
    }

    /// The Levenshtein distance between `source` and `target` when it is at most `limit`; `None`
    /// when it is larger.
    pub(super) fn distance(source: &[usize], target: &[usize], limit: usize, rows: &mut Rows) -> Option<usize> {
        if source.len().abs_diff(target.len()) > limit {
            return None;
        }
        if source.is_empty() {
            return Some(target.len());
        }
        if target.is_empty() {
            return Some(source.len());
        }

        let beyond = limit + 1;
        let width = target.len() + 1;
        if rows.previous.len() < width {
            rows.previous = vec![0; width];
            rows.current = vec![0; width];
        }
        for (column, cell) in rows.previous[..width].iter_mut().enumerate() {
            *cell = column.min(beyond);
        }
        for row in 1..=source.len() {
            let low = row.saturating_sub(limit).max(1);
            let high = target.len().min(row + limit);
            // The cell left of the band: column 0 on the early rows, out of reach otherwise.
            rows.current[low - 1] = if low == 1 { row.min(beyond) } else { beyond };
            let mut row_minimum = rows.current[low - 1];
            let source_code = source[row - 1];
            for column in low..=high {
                let substitution = rows.previous[column - 1] + usize::from(source_code != target[column - 1]);
                let value = substitution
                    .min(rows.previous[column] + 1)
                    .min(rows.current[column - 1] + 1)
                    .min(beyond);
                rows.current[column] = value;
                row_minimum = row_minimum.min(value);
            }
            // The next row reads one column further right, which this row never computed.
            if high < target.len() {
                rows.current[high + 1] = beyond;
            }
            if row_minimum > limit {
                return None;
            }
            std::mem::swap(&mut rows.previous, &mut rows.current);
        }
        let result = rows.previous[target.len()];
        (result <= limit).then_some(result)
    }
}

/// The similarity search takes shortcuts for speed; these tests check it against the plain
/// `edit_distance` it must agree with, on many seeded random inputs, as the Mac app's
/// `TermSimilarityTests` do. The generator draws as Swift's does, so the inputs are theirs too.
#[cfg(test)]
mod tests {
    use std::ops::RangeInclusive;

    use super::bounded_edit_distance::{self, Rows};
    use super::*;

    #[test]
    fn bounded_distance_agrees_with_levenshtein() {
        let mut random = SeededGenerator::new(1);
        // One set of rows for every call, as the search uses them: stale values must not leak.
        let mut rows = Rows::default();
        for _ in 0..5000 {
            let source: Vec<usize> = (0..random.int(0..=9)).map(|_| random.int(0..=3)).collect();
            let target: Vec<usize> = (0..random.int(0..=9)).map(|_| random.int(0..=3)).collect();
            // Swift draws the limit from -1...7. A negative limit, which no distance is within,
            // can't be passed here, so it stands as `None`.
            let limit = random.int(0..=8).checked_sub(1);
            let exact = edit_distance::levenshtein(&source, &target);
            let expected = limit.filter(|&limit| exact <= limit).map(|_| exact);
            let actual = limit.and_then(|limit| bounded_edit_distance::distance(&source, &target, limit, &mut rows));
            assert_eq!(actual, expected, "{source:?} → {target:?}, limit {limit:?}");
        }
    }

    /// Finds the same terms, in the same order, as `edit_distance`.
    #[test]
    fn agrees_with_normalized_similarity() {
        for threshold in [0.0, 0.5, 0.7, 0.75, 0.8, 0.9, 1.0, 1.5, f64::NAN] {
            let mut random = SeededGenerator::new(2);
            let mut found = 0;
            for _ in 0..60 {
                let phrases_by_term: Vec<Vec<String>> = (0..random.int(1..=12))
                    .map(|_| (0..random.int(1..=3)).map(|_| phrase(&mut random)).collect())
                    .collect();
                let text = (0..random.int(0..=12))
                    .map(|_| word(&mut random))
                    .collect::<Vec<_>>()
                    .join(" ");
                let similarity = TermSimilarity::new(&phrases_by_term, threshold);
                let excluded = random.index(phrases_by_term.len());

                let actual = similarity.similar_terms(&text, |index| index == excluded);

                let units = units(&text);
                let mut scored: Vec<(usize, f64)> = phrases_by_term
                    .iter()
                    .enumerate()
                    .filter(|&(index, _)| index != excluded)
                    .filter_map(|(index, phrases)| {
                        let best = phrases
                            .iter()
                            .filter(|phrase| !edit_distance::normalize(phrase).is_empty())
                            .flat_map(|form| {
                                units
                                    .iter()
                                    .map(move |unit| edit_distance::normalized_similarity(form, unit))
                            })
                            .max_by(f64::total_cmp)?;
                        (best >= threshold).then_some((index, best))
                    })
                    .collect();
                scored.sort_by(|lhs, rhs| rhs.1.total_cmp(&lhs.1).then(lhs.0.cmp(&rhs.0)));
                let expected: Vec<usize> = scored.into_iter().map(|(index, _)| index).collect();
                assert_eq!(
                    actual, expected,
                    "{phrases_by_term:?} in {text:?}, threshold {threshold}"
                );
                found += expected.len();
            }
            // Guards against a comparison that passes only because nothing is ever similar.
            if threshold <= 0.9 {
                assert!(found > 0, "threshold {threshold}");
            }
        }
    }

    #[test]
    fn no_text_or_no_terms_find_nothing() {
        let kafka = TermSimilarity::new(&[vec!["Kafka".to_owned()]], 0.5);
        assert!(kafka.similar_terms("", |_| false).is_empty());
        assert!(
            TermSimilarity::new(&[], 0.5)
                .similar_terms("kafka", |_| false)
                .is_empty()
        );
    }

    /// "é" written as one code point and as "e" plus a combining accent is the same character.
    #[test]
    fn canonically_equivalent_characters_match() {
        let similarity = TermSimilarity::new(&[vec!["Caf\u{E9}".to_owned()]], 1.0);
        assert_eq!(similarity.similar_terms("cafe\u{301}", |_| false), [0]);
    }

    /// Short words over a small alphabet, so near misses are common. The accented letters test
    /// grapheme handling and the capitals test normalisation.
    const LETTERS: [&str; 8] = ["a", "b", "c", "e", "\u{E9}", "e\u{301}", "K", "-"];

    fn word(random: &mut SeededGenerator) -> String {
        (0..random.int(1..=6)).map(|_| *random.element(&LETTERS)).collect()
    }

    fn phrase(random: &mut SeededGenerator) -> String {
        (0..random.int(1..=2))
            .map(|_| word(random))
            .collect::<Vec<_>>()
            .join(" ")
    }

    /// SplitMix64: a small generator with a fixed seed, so every run tests the same inputs.
    ///
    /// It draws from a range as Swift's `Int.random(in:using:)` does, by Lemire's nearly
    /// divisionless method, so the same seed gives the Mac app's tests' inputs.
    struct SeededGenerator {
        state: u64,
    }

    impl SeededGenerator {
        fn new(seed: u64) -> Self {
            Self { state: seed }
        }

        fn next(&mut self) -> u64 {
            self.state = self.state.wrapping_add(0x9E37_79B9_7F4A_7C15);
            let mut value = self.state;
            value = (value ^ (value >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
            value = (value ^ (value >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
            value ^ (value >> 31)
        }

        /// `Int.random(in: range, using:)`, for a range of non-negative numbers.
        fn int(&mut self, range: RangeInclusive<usize>) -> usize {
            let (low, high) = range.into_inner();
            low + self.index(high - low + 1)
        }

        /// `Int.random(in: 0..<count, using:)`, which is also how `randomElement(using:)` picks.
        fn index(&mut self, count: usize) -> usize {
            self.below(count as u64) as usize
        }

        /// `randomElement(using:)` of a collection that is not empty.
        fn element<'a, T>(&mut self, items: &'a [T]) -> &'a T {
            &items[self.index(items.len())]
        }

        /// `next(upperBound:)`: a number below `bound`, the high half of a random number times
        /// `bound`, drawn again while the low half falls where it would bias the result.
        fn below(&mut self, bound: u64) -> u64 {
            let mut product = u128::from(self.next()) * u128::from(bound);
            if (product as u64) < bound {
                let threshold = bound.wrapping_neg() % bound;
                while (product as u64) < threshold {
                    product = u128::from(self.next()) * u128::from(bound);
                }
            }
            (product >> 64) as u64
        }
    }
}
