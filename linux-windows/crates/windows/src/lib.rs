//! The app's desktop on Windows, as `lt-wayland` is on Linux: typing dictated text into the
//! focused app, the clipboard, and what the focused field is.
//!
//! Text is typed as Unicode keystrokes (SendInput), so it goes in whatever the script and the
//! keyboard layout, and the clipboard is untouched. Where nothing would take it, the text is left
//! on the clipboard for the user to paste. Windows says what the focused field is only for its
//! own edit controls; other fields are typed into on one line, as a field nothing is known about
//! is on Linux. Dictated text is never logged.
//!
//! What decides where the text goes, and how it is typed, is platform-free and tested on any
//! system; the rest builds on Windows only.

// On other systems nothing uses them but their tests.
#![cfg_attr(not(windows), allow(dead_code))]

#[cfg(windows)]
mod clipboard;
#[cfg(windows)]
mod console;
mod field;
#[cfg(windows)]
mod session;
#[cfg(windows)]
mod system;
mod text;

#[cfg(windows)]
pub use console::attach_parent_console;
#[cfg(windows)]
pub use session::{SessionError, TypingSession};
