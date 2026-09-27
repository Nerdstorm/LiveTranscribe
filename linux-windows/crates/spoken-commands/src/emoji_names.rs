use std::collections::HashMap;
use std::sync::{Arc, LazyLock};

use lt_shared::swift_string::{self as s};

/// Every name the Mac app accepts for an emoji, before the plural rule, as its golden test wrote
/// them: its common names and each emoji's Unicode name that macOS resolves. Reading the Mac
/// app's table keeps the two apps on the same names, where Unicode data differs by version and
/// name lookup rules differ by library.
const TABLE: &str = include_str!("../../../../Fixtures/golden/emoji-names.tsv");

static STANDARD: LazyLock<Arc<EmojiNames>> = LazyLock::new(|| {
    let (names, malformed) = parse(TABLE);
    if malformed > 0 {
        tracing::error!("Skipped {malformed} malformed lines of the emoji names table");
    }
    Arc::new(EmojiNames::new(names))
});

/// Emoji by spoken name: the names people say ("thumbs up", "heart", "smiley"), any emoji's
/// Unicode name ("rocket", "fireworks", "face with tears of joy"), and either in the plural
/// ("hearts").
#[derive(Clone, Debug, Default)]
pub struct EmojiNames {
    by_name: HashMap<String, String>,
}

impl EmojiNames {
    /// The Mac app's names; see `Fixtures/golden/emoji-names.tsv`.
    pub fn standard() -> Arc<Self> {
        Arc::clone(&STANDARD)
    }

    /// Emoji by name, the names in the lowercase words [`lt_shared::edit_distance::normalize`] gives.
    pub fn new(by_name: HashMap<String, String>) -> Self {
        let by_name = by_name
            .into_iter()
            .map(|(name, emoji)| (s::canonical_key(&name).into_owned(), emoji))
            .collect();
        Self { by_name }
    }

    /// The emoji named by `words`, lowercase and without punctuation; `None` if they name none.
    pub fn emoji(&self, words: &[&str]) -> Option<String> {
        let (&last, rest) = words.split_last()?;
        if let Some(emoji) = self.look_up(&words.join(" ")) {
            return Some(emoji);
        }
        if s::character_count(last) <= 3 || !s::has_suffix(last, "s") || s::has_suffix(last, "ss") {
            return None;
        }
        let mut singular = rest.to_vec();
        singular.push(s::drop_last(last, 1));
        self.look_up(&singular.join(" "))
    }

    fn look_up(&self, name: &str) -> Option<String> {
        self.by_name.get(s::canonical_key(name).as_ref()).cloned()
    }
}

/// The names and emoji in `table` (name, scalars in hex, emoji; `#` starts a comment), and the
/// number of lines that could not be read.
fn parse(table: &str) -> (HashMap<String, String>, usize) {
    let mut names = HashMap::new();
    let mut malformed = 0;
    for line in table.lines().filter(|line| !line.is_empty() && !line.starts_with('#')) {
        let mut columns = line.split('\t');
        let name = columns.next().unwrap_or_default();
        let emoji = columns.next().and_then(|scalars| {
            scalars
                .split(' ')
                .map(|hex| u32::from_str_radix(hex, 16).ok().and_then(char::from_u32))
                .collect::<Option<String>>()
        });
        match emoji {
            Some(emoji) if !name.is_empty() && !emoji.is_empty() => {
                names.insert(name.to_owned(), emoji);
            }
            _ => malformed += 1,
        }
    }
    (names, malformed)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_table_is_whole() {
        let (names, malformed) = parse(TABLE);
        assert_eq!(malformed, 0);
        assert!(names.len() > 1_500, "{} names", names.len());
    }

    #[test]
    fn finds_common_unicode_and_plural_names() {
        let names = EmojiNames::standard();
        assert_eq!(names.emoji(&["fireworks"]).as_deref(), Some("\u{1F386}"));
        assert_eq!(names.emoji(&["thumbs", "up"]).as_deref(), Some("\u{1F44D}"));
        assert_eq!(names.emoji(&["rockets"]).as_deref(), Some("\u{1F680}"));
        assert_eq!(names.emoji(&["fire", "works"]), None);
        assert_eq!(names.emoji(&[]), None);
    }
}
