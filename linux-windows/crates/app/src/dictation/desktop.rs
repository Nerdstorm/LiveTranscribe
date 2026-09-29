//! What dictation needs from the desktop it runs on: what the focused field is, typing into it,
//! the clipboard, and the panel by the mouse pointer. It is one trait, so the rest of dictation (the
//! engine and its speech model, the controller's view of the machine, the tray and Settings) is the
//! same on every system, and each system's part is a module of its own: [`linux`], through
//! lt-wayland.
//!
//! Every call returns at once: the desktop types and draws on threads of its own, and says how an
//! insertion went through its callback.

#[cfg(target_os = "linux")]
mod linux;

use lt_dictation_ui::{PanelContent, PanelView};
use lt_insertion::{Inserted, InsertionConfiguration, InsertionTarget};

#[cfg(target_os = "linux")]
pub(crate) use linux::{connect, hotkey_blocker, hotkey_problem};

/// What the dictation panel needs; without it, no panel shows.
pub(crate) struct PanelConfiguration {
    pub(crate) view: PanelView,
    /// The microphone's level now, for the meter.
    pub(crate) level: Box<dyn Fn() -> f32 + Send>,
}

/// Called once with how an insertion went: what went in, or why nothing did.
pub(crate) type InsertionDone = Box<dyn FnOnce(Result<Inserted, String>) + Send>;

/// The desktop, as dictation uses it.
pub(crate) trait Desktop: Send {
    /// The focused field, as far as the desktop can tell: the default target when it can't.
    fn target(&self) -> InsertionTarget;

    /// A dictation is on its way: whatever typing it needs ready can be made ready now.
    fn prepare(&self);

    /// Types `text` into the focused field, then calls `done`. Insertions run one at a time, in
    /// order.
    fn insert(&self, text: String, done: InsertionDone);

    /// Puts `text` on the clipboard, as copying it in an app would.
    fn copy(&self, text: String);

    /// Types with `configuration` from the next insertion on.
    fn set_insertion(&self, configuration: InsertionConfiguration);

    /// Shows the dictation panel with `content`, or hides it.
    fn show_panel(&self, content: Option<PanelContent>);
}

/// `text` with its first letter in upper case, for an error's message at the start of a sentence.
fn capitalised(text: &str) -> String {
    let mut characters = text.chars();
    characters
        .next()
        .map(|first| first.to_uppercase().chain(characters).collect())
        .unwrap_or_default()
}
