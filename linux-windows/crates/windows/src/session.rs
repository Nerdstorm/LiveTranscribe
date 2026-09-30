//! The typing session: a thread of its own types dictated text, one insertion at a time and in
//! order, and puts text on the clipboard. What the focused field is, the caller's thread asks
//! Windows itself, as that only reads.
//!
//! Text is typed as Unicode keystrokes into the window that has the keyboard, and left on the
//! clipboard, for the user to paste, where nothing would take it: no window has the keyboard, the
//! desktop or the taskbar has it, the tray's menu has just left it with this app's hidden window,
//! or the focused app runs as administrator, which ignores keystrokes from an app that doesn't.

use std::sync::mpsc::{self, Receiver, Sender};
use std::thread;
use std::time::{Duration, Instant};

use lt_insertion::{Inserted, InsertionMethod, InsertionTarget};

use crate::text::{self, PIECE_LETTERS};
use crate::{clipboard, field, system};

/// Between pieces of the text, for the app to take in the last one before focus is checked again.
const PIECE_PAUSE: Duration = Duration::from_millis(10);
/// How long typing waits for the modifier keys to be let go, such as the hotkey's own Ctrl.
const MODIFIER_WAIT: Duration = Duration::from_secs(1);
const MODIFIER_POLL: Duration = Duration::from_millis(10);

type Callback = Box<dyn FnOnce(Result<Inserted, SessionError>) + Send>;

/// Called once with an insertion's result; dropped uncalled, it reports that the session stopped.
struct Done(Option<Callback>);

impl Done {
    fn finish(mut self, result: Result<Inserted, SessionError>) {
        if let Some(callback) = self.0.take() {
            callback(result);
        }
    }
}

impl Drop for Done {
    fn drop(&mut self) {
        if let Some(callback) = self.0.take() {
            callback(Err(SessionError::Stopped));
        }
    }
}

enum Command {
    Insert { text: String, done: Done },
    Copy(String),
}

/// The app's typing session on Windows, on a thread of its own.
pub struct TypingSession {
    commands: Sender<Command>,
}

impl TypingSession {
    pub fn start() -> Result<Self, SessionError> {
        let (commands, received) = mpsc::channel();
        thread::Builder::new()
            .name("typing".to_owned())
            .spawn(move || run(&received))
            .map_err(|error| SessionError::Thread(error.to_string()))?;
        Ok(Self { commands })
    }

    /// The focused field, as far as Windows says: a password field or one on several lines, for
    /// the system's own edit controls; for any other, a field nothing is known about.
    pub fn target(&self) -> InsertionTarget {
        focused_target()
    }

    /// Types `text` into the focused field, then calls `done` from the session's thread.
    pub fn insert(&self, text: String, done: impl FnOnce(Result<Inserted, SessionError>) + Send + 'static) {
        // A failed send drops the command, and with it `done`, which then reports the stop.
        let _ = self.commands.send(Command::Insert {
            text,
            done: Done(Some(Box::new(done))),
        });
    }

    /// Puts `text` on the clipboard, as copying it in an app would.
    pub fn copy(&self, text: String) {
        let _ = self.commands.send(Command::Copy(text));
    }
}

fn run(commands: &Receiver<Command>) {
    // Ends when the handle, and with it every sender, has gone.
    for command in commands {
        match command {
            Command::Insert { text, done } => done.finish(insert(&text)),
            Command::Copy(text) => {
                if let Err(error) = clipboard::copy(&text) {
                    tracing::warn!("Couldn't copy the last dictation: {error}");
                }
            }
        }
    }
}

fn focused_target() -> InsertionTarget {
    system::foreground()
        .and_then(|foreground| system::focused_control(foreground.thread))
        .map_or_else(InsertionTarget::default, |(class, style)| field::target(&class, style))
}

/// Where dictated text goes now.
enum Destination {
    /// Typed into the window with this id.
    Field {
        window: usize,
        multiline: bool,
    },
    /// Left on the clipboard, for this reason.
    Clipboard(&'static str),
    Secure,
}

fn destination() -> Destination {
    let Some(foreground) = system::foreground() else {
        return Destination::Clipboard("no window has the keyboard");
    };
    if foreground.process == system::this_process() && !foreground.is_visible() {
        return Destination::Clipboard("the tray menu left the keyboard with Live Transcribe");
    }
    if field::is_shell(&foreground.class()) {
        return Destination::Clipboard("the desktop or the taskbar has the keyboard");
    }
    if !system::can_type_into(foreground.process) {
        return Destination::Clipboard("the focused app runs as administrator");
    }
    let target = system::focused_control(foreground.thread)
        .map_or_else(InsertionTarget::default, |(class, style)| field::target(&class, style));
    if target.is_secure {
        return Destination::Secure;
    }
    Destination::Field {
        window: foreground.id(),
        multiline: target.allows_line_breaks,
    }
}

fn insert(text: &str) -> Result<Inserted, SessionError> {
    if !modifiers_let_go() {
        return leave_on_clipboard(text, "a modifier key is held down");
    }
    let (window, multiline) = match destination() {
        Destination::Field { window, multiline } => (window, multiline),
        Destination::Clipboard(reason) => return leave_on_clipboard(text, reason),
        Destination::Secure => return Err(SessionError::SecureField),
    };
    let started = Instant::now();
    let pieces = text::pieces(&text::typeable(text, multiline), PIECE_LETTERS);
    let mut typed = 0;
    for (index, piece) in pieces.iter().enumerate() {
        if index > 0 {
            thread::sleep(PIECE_PAUSE);
            if !modifiers_let_go() {
                tracing::warn!("A modifier key was held after {typed} characters; typing stopped");
                return Err(SessionError::ModifierHeld { characters: typed });
            }
            if !matches!(destination(), Destination::Field { window: now, .. } if now == window) {
                tracing::warn!("Focus left the field after {typed} characters");
                return Err(SessionError::FocusLost { characters: typed });
            }
        }
        system::type_units(&piece.units).map_err(|detail| SessionError::Input {
            detail,
            characters: typed,
        })?;
        typed += piece.characters;
    }
    tracing::info!(
        "Typed {typed} characters as keystrokes in {} ms",
        started.elapsed().as_millis()
    );
    Ok(Inserted {
        characters: typed,
        method: InsertionMethod::Keystrokes,
        read: true,
        // The clipboard was never touched.
        restored: true,
    })
}

/// Waits for Shift, Ctrl, Alt and Windows to be let go; `false` if one is still down after
/// [`MODIFIER_WAIT`].
fn modifiers_let_go() -> bool {
    let deadline = Instant::now() + MODIFIER_WAIT;
    while system::modifier_held() {
        if Instant::now() >= deadline {
            return false;
        }
        thread::sleep(MODIFIER_POLL);
    }
    true
}

/// Leaves `text` on the clipboard for the user to paste: nothing took it.
fn leave_on_clipboard(text: &str, reason: &str) -> Result<Inserted, SessionError> {
    tracing::info!("Leaving the text on the clipboard: {reason}");
    clipboard::leave(text).map_err(SessionError::Clipboard)?;
    Ok(Inserted {
        characters: text.chars().count(),
        method: InsertionMethod::Keystrokes,
        read: false,
        restored: false,
    })
}

#[derive(Debug)]
pub enum SessionError {
    /// The session's thread couldn't start.
    Thread(String),
    /// The session's thread has ended.
    Stopped,
    /// The focused field is a password field, so nothing was typed.
    SecureField,
    /// Focus left the field partway through a long text.
    FocusLost { characters: usize },
    /// A modifier key was held partway through, and typing on would make shortcuts.
    ModifierHeld { characters: usize },
    /// Windows didn't take the keystrokes.
    Input { detail: String, characters: usize },
    /// Nothing could take the text, and the clipboard couldn't either.
    Clipboard(String),
}

impl std::fmt::Display for SessionError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Thread(detail) => write!(formatter, "the typing thread couldn't start: {detail}"),
            Self::Stopped => formatter.write_str("the typing thread has stopped"),
            Self::SecureField => formatter.write_str("the focused field is a password field"),
            Self::FocusLost { characters } => write!(
                formatter,
                "the field lost focus after {characters} characters; the rest wasn't typed"
            ),
            Self::ModifierHeld { characters } => write!(
                formatter,
                "a modifier key was held down after {characters} characters; the rest wasn't typed"
            ),
            Self::Input { detail, characters: 0 } => formatter.write_str(detail),
            Self::Input { detail, characters } => {
                write!(formatter, "{detail}, after {characters} characters")
            }
            Self::Clipboard(detail) => formatter.write_str(detail),
        }
    }
}

impl std::error::Error for SessionError {}
