//! Typing dictated text into the focused app: the platform-free parts, as the Mac app's Insertion
//! module has them. What is known about the focused field ([`InsertionTarget`]), what the
//! clipboard holds while text is pasted ([`ClipboardContents`]), and what an insertion did
//! ([`Inserted`]). How each platform types is elsewhere: `lt-wayland` on Linux, which commits
//! through the input method where the field takes it, and otherwise pastes: the text goes on the
//! clipboard, the paste shortcut is typed, and once the app has read the text the clipboard gets
//! back what it held. Text nothing read stays on the clipboard for the user to paste. `lt-windows`
//! on Windows types the text as Unicode keystrokes, and leaves it on the clipboard when nothing
//! that takes text has the focus.
//!
//! Dictated text is never logged.

mod clipboard;

use std::time::Duration;

pub use clipboard::{ClipboardContents, holds_data, is_text};

/// The field dictated text would go into, as far as the platform can tell. The default is a
/// field nothing is known about: typed into, on one line (it could be a terminal), with no space
/// added.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct InsertionTarget {
    /// A password field: nothing is typed or copied into it, and nothing said is transcribed.
    pub is_secure: bool,
    /// The field takes several lines, so spoken line breaks can be newlines.
    pub allows_line_breaks: bool,
    /// The character before the cursor, when the field says.
    pub preceding: Option<char>,
    /// The field asks that what is typed into it isn't kept, as a private browser window does:
    /// the text goes in, but isn't remembered as the last dictation.
    pub is_private: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct InsertionConfiguration {
    /// How long after the app reads the text the clipboard is put back.
    pub restore_delay: Duration,
    /// How long to wait for the app to read the text. When nothing that takes text has focus,
    /// nothing does, and the text is left on the clipboard.
    pub read_timeout: Duration,
}

/// How dictated text went in.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum InsertionMethod {
    /// Committed through the input method, straight into the focused field. The clipboard is
    /// untouched.
    InputMethod,
    /// Pasted through the clipboard.
    Paste,
    /// Typed as Unicode keystrokes (Windows' SendInput), straight into the focused field. The
    /// clipboard is untouched.
    Keystrokes,
}

impl InsertionMethod {
    /// How the Mac app's history names it.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::InputMethod => "input method",
            Self::Paste => "paste",
            Self::Keystrokes => "keystrokes",
        }
    }
}

/// What an insertion did.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Inserted {
    pub characters: usize,
    pub method: InsertionMethod,
    /// The focused app took the text: always through the input method; for a paste, it read the
    /// clipboard, so the text was very likely pasted. When nothing did, the text was left on the
    /// clipboard (unless something else was copied meanwhile).
    pub read: bool,
    /// The clipboard got back what it held before. Not when the text was left there, nor when
    /// something else was copied meanwhile, which then stays.
    pub restored: bool,
}
