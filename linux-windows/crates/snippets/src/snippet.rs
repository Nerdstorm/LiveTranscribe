use lt_shared::edit_distance;

/// A phrase the user says ("my calendar link") and the text it stands for (a URL, an address, a
/// signature).
///
/// Snippets are expanded after the language model has run, never by it: the model only sees an
/// opaque placeholder, so it cannot "correct" a URL or an address into something else.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Snippet {
    /// What the user says. Matched as whole words, ignoring case and punctuation.
    pub trigger: String,
    /// Inserted verbatim in place of the trigger, including newlines, URLs and emoji.
    pub expansion: String,
}

impl Snippet {
    pub fn new(trigger: &str, expansion: &str) -> Self {
        Self {
            trigger: trigger.to_owned(),
            expansion: expansion.to_owned(),
        }
    }

    /// The trigger's words as matching sees them: lowercased, punctuation removed, hyphens split
    /// (see [`edit_distance::normalize`]).
    pub fn trigger_words(&self) -> Vec<String> {
        edit_distance::words(&edit_distance::normalize(&self.trigger))
            .into_iter()
            .map(str::to_owned)
            .collect()
    }
}
