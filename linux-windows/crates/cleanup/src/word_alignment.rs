use crate::words::same;

/// What lies between two consecutive matched words: the raw indices with no counterpart, and the
/// cleaned indices that stand in their place.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Gap {
    pub(crate) deleted: Vec<usize>,
    pub(crate) inserted: Vec<usize>,
}

/// The words the speaker said lined up with the words cleanup returned: a longest common
/// subsequence of the two, and the gaps between its matched words.
///
/// The output guard's checks for lost meaning share one alignment per review. Both lists are
/// normalised words.
#[derive(Clone, Debug)]
pub(crate) struct WordAlignment {
    pub(crate) raw: Vec<String>,
    pub(crate) cleaned: Vec<String>,
    /// For each raw index, the cleaned index it is matched to; `None` when it is in a gap.
    pub(crate) matches: Vec<Option<usize>>,
    pub(crate) gaps: Vec<Gap>,
}

impl WordAlignment {
    pub(crate) fn new(raw: Vec<String>, cleaned: Vec<String>) -> Self {
        let (n, m) = (raw.len(), cleaned.len());
        // lengths[i * (m + 1) + j]: the LCS length of raw[i...] and cleaned[j...].
        let mut lengths = vec![0_usize; (n + 1) * (m + 1)];
        let at = |i: usize, j: usize| i * (m + 1) + j;
        for i in (0..n).rev() {
            for j in (0..m).rev() {
                lengths[at(i, j)] = if same(&raw[i], &cleaned[j]) {
                    lengths[at(i + 1, j + 1)] + 1
                } else {
                    lengths[at(i + 1, j)].max(lengths[at(i, j + 1)])
                };
            }
        }

        let mut matches = vec![None; n];
        let mut gaps = Vec::new();
        let mut deleted = Vec::new();
        let mut inserted = Vec::new();
        let mut close_gap = |deleted: &mut Vec<usize>, inserted: &mut Vec<usize>| {
            if !deleted.is_empty() || !inserted.is_empty() {
                gaps.push(Gap {
                    deleted: std::mem::take(deleted),
                    inserted: std::mem::take(inserted),
                });
            }
        };
        let (mut i, mut j) = (0, 0);
        while i < n || j < m {
            if i < n && j < m && same(&raw[i], &cleaned[j]) {
                close_gap(&mut deleted, &mut inserted);
                matches[i] = Some(j);
                i += 1;
                j += 1;
            } else if j == m || (i < n && lengths[at(i + 1, j)] >= lengths[at(i, j + 1)]) {
                deleted.push(i);
                i += 1;
            } else {
                inserted.push(j);
                j += 1;
            }
        }
        close_gap(&mut deleted, &mut inserted);
        Self {
            raw,
            cleaned,
            matches,
            gaps,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn words(values: &[&str]) -> Vec<String> {
        values.iter().map(|&value| value.to_owned()).collect()
    }

    fn gap(deleted: &[usize], inserted: &[usize]) -> Gap {
        Gap {
            deleted: deleted.to_vec(),
            inserted: inserted.to_vec(),
        }
    }

    #[test]
    fn gaps_pair_deletions_with_what_replaced_them() {
        let alignment = WordAlignment::new(words(&["a", "b", "c", "d", "e"]), words(&["a", "x", "d", "e", "f"]));
        assert_eq!(alignment.gaps, [gap(&[1, 2], &[1]), gap(&[], &[4])]);
        assert_eq!(alignment.matches, [Some(0), None, None, Some(2), Some(3)]);
    }

    #[test]
    fn a_moved_word_is_deleted_in_one_gap_and_inserted_in_another() {
        let alignment = WordAlignment::new(
            words(&["tomorrow", "i", "will", "send", "it"]),
            words(&["i", "will", "send", "it", "tomorrow"]),
        );
        assert_eq!(alignment.gaps, [gap(&[0], &[]), gap(&[], &[4])]);
    }

    #[test]
    fn empty_text_has_no_gaps_or_only_one() {
        assert!(WordAlignment::new(Vec::new(), Vec::new()).gaps.is_empty());
        assert_eq!(WordAlignment::new(words(&["a"]), Vec::new()).gaps, [gap(&[0], &[])]);
    }

    #[test]
    fn canonically_equivalent_words_match() {
        let alignment = WordAlignment::new(words(&["caf\u{E9}"]), words(&["cafe\u{301}"]));
        assert_eq!(alignment.matches, [Some(0)]);
        assert!(alignment.gaps.is_empty());
    }
}
