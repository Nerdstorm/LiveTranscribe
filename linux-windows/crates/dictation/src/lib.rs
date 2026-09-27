//! Turns a transcript into the text dictation types: snippets, spoken commands and vocabulary,
//! cleanup at the chosen level, then layout and the snippets' expansions. Mirrors the Mac app's
//! `Dictation` module (Packages/LiveTranscribeKit/Sources/Dictation); the golden cases in
//! `Fixtures/golden` check that both type the same text.

mod dictation_processor;
mod prepared_dictation;

pub use dictation_processor::{Configuration, Output, finish};
