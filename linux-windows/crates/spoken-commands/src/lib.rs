//! Phrases dictation treats as commands rather than words: emoji ("emoji fireworks" → 🎆),
//! dictated punctuation ("question mark" → ?), line breaks ("new paragraph") and email and web
//! addresses ("john dot smith at example dot com").
//!
//! Like snippets, they apply at every cleanup level, before the language model runs: an emoji or
//! an address goes behind a placeholder the model cannot change, and a line break behind one it
//! cannot drop. Each kind is a [`lt_shared::PhraseMatcher`]; a new kind of command is one more
//! matcher in [`matchers`]. Each module mirrors the file of the same name in the Mac app's
//! `SpokenCommands` module (Packages/LiveTranscribeKit/Sources/SpokenCommands).

mod address_command;
mod emoji_command;
mod emoji_names;
mod line_break_command;
mod punctuation_command;
mod spoken_commands;

pub use address_command::{AddressCommand, COMMON_TOP_LEVEL_DOMAINS};
pub use emoji_command::EmojiCommand;
pub use emoji_names::EmojiNames;
pub use line_break_command::LineBreakCommand;
pub use punctuation_command::{Mark, Pair, PunctuationCommand, STANDARD_MARKS, STANDARD_PAIRS};
pub use spoken_commands::{matchers, tidy_line_breaks};
