//! The user's vocabulary: spoken variants rewritten to their canonical spelling, and the terms the
//! cleanup prompt lists, most relevant first. Mirrors the Mac app's `Vocabulary` module
//! (Packages/LiveTranscribeKit/Sources/Vocabulary).

mod distinctive_casing;
mod phrase_matcher;
mod term_similarity;
mod vocabulary_entry;
mod vocabulary_replacer;
mod vocabulary_selector;
mod word_tokenizer;

pub use vocabulary_entry::VocabularyEntry;
pub use vocabulary_replacer::VocabularyReplacer;
pub use vocabulary_selector::VocabularySelector;
