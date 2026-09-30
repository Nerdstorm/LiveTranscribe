//! Dictation: the flow from the hotkey to the text in the app ([`DictationController`]), and
//! what turns a transcript into the text it types: snippets, spoken commands and vocabulary,
//! cleanup at the chosen level, then layout and the snippets' expansions. Mirrors the Mac app's
//! `Dictation` module (Packages/LiveTranscribeKit/Sources/Dictation); the golden cases in
//! `Fixtures/golden` check that both type the same text.

mod dictation_controller;
mod dictation_notice;
mod dictation_processor;
pub mod insertion_spacing;
mod prepared_dictation;

pub use dictation_controller::{ControllerConfiguration, Dependencies, DictationController, Job, Phase, Recording};
pub use dictation_notice::Notice;
pub use dictation_processor::{Configuration, Output, Pending, Prepared, finish, prepare};
