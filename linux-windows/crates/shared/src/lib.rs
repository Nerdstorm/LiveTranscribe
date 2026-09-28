//! What the slices share: text with Swift's semantics, the phrase protector and its
//! placeholders, word normalisation, the cleanup levels and the audio format.
//!
//! Each module mirrors the file of the same name in the Mac app's `Shared` module
//! (Packages/LiveTranscribeKit/Sources/Shared), and the golden cases in `Fixtures/golden` keep the
//! two in step. Dictated text is never logged: only counts are.

pub mod audio_format;
mod cleanup_level;
pub mod edit_distance;
pub mod phrase_grammar;
mod phrase_protector;
pub mod placeholder_token;
mod protected_text;
pub mod sentence_case;
pub mod swift_string;
mod tokenized_text;

pub use cleanup_level::CleanupLevel;
pub use phrase_protector::{InlineText, PhraseMatch, PhraseMatcher, PhraseProtector, Replacement};
pub use protected_text::{Placeholder, ProtectedText, Role};
pub use tokenized_text::{TokenizedText, Word, token_edges};
