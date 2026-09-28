//! The user's vocabulary: spoken variants rewritten to their canonical spelling. Mirrors the Mac
//! app's `Vocabulary` module (Packages/LiveTranscribeKit/Sources/Vocabulary).

mod distinctive_casing;
mod phrase_matcher;
mod vocabulary_entry;
mod vocabulary_replacer;
mod word_tokenizer;

pub use vocabulary_entry::VocabularyEntry;
pub use vocabulary_replacer::VocabularyReplacer;
