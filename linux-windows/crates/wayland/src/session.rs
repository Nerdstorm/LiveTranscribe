//! The session's handle. The session's thread owns the Wayland connection; the handle sends it
//! commands, and wakes it through a pipe, as it waits on the connection too.

use std::os::fd::OwnedFd;
use std::sync::mpsc::{self, Sender};
use std::thread;
use std::time::Duration;

use lt_dictation_ui::{PanelContent, PanelView};
use lt_insertion::{Inserted, InsertionConfiguration, InsertionTarget};
use rustix::pipe::{PipeFlags, pipe_with};

use crate::event_loop::Session;

/// How long [`WaylandSession::target`] waits for an answer. Longer than saving the clipboard can
/// keep the session busy.
const TARGET_TIMEOUT: Duration = Duration::from_secs(3);

pub struct SessionConfiguration {
    pub insertion: InsertionConfiguration,
    /// What the dictation panel needs; without it, no panel shows.
    pub panel: Option<PanelConfiguration>,
}

pub struct PanelConfiguration {
    pub view: PanelView,
    /// The microphone's level now, for the meter.
    pub level: Box<dyn Fn() -> f32 + Send>,
}

/// What this desktop lets the session do beyond pasting.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Capabilities {
    /// Text goes straight into fields that take an input method. Not when the compositor lacks
    /// input-method-v2, nor when another input method (IBus, Fcitx) has the seat.
    pub input_method: bool,
    /// The panel can show (wlr-layer-shell).
    pub overlay: bool,
    /// The panel follows the mouse pointer (ext-image-copy-capture-v1's cursor sessions);
    /// otherwise it shows at the bottom of the screen.
    pub follows_pointer: bool,
}

type Callback = Box<dyn FnOnce(Result<Inserted, SessionError>) + Send>;

/// Called once with an insertion's result; dropped uncalled, it reports that the session stopped.
pub(crate) struct Done(Option<Callback>);

impl Done {
    pub(crate) fn finish(mut self, result: Result<Inserted, SessionError>) {
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

pub(crate) enum Command {
    /// Reply with the focused field.
    Target(Sender<InsertionTarget>),
    Prepare,
    Insert {
        text: String,
        done: Done,
    },
    Copy(String),
    Configure(InsertionConfiguration),
    Panel(Option<PanelContent>),
}

/// The app's Wayland session, on a thread of its own.
pub struct WaylandSession {
    commands: Sender<Command>,
    wake: OwnedFd,
    capabilities: Capabilities,
}

impl WaylandSession {
    /// Connects to the compositor and checks it offers what typing needs.
    pub fn connect(configuration: SessionConfiguration) -> Result<Self, SessionError> {
        let (commands, received) = mpsc::channel();
        let (wake_reader, wake) = pipe_with(PipeFlags::CLOEXEC | PipeFlags::NONBLOCK)
            .map_err(|error| SessionError::Connection(format!("couldn't make a pipe: {error}")))?;
        let (ready, answer) = mpsc::channel();
        thread::Builder::new()
            .name("wayland".to_owned())
            .spawn(move || match Session::connect(configuration) {
                Ok(mut session) => {
                    let _ = ready.send(Ok(session.capabilities()));
                    session.run(&received, wake_reader);
                }
                Err(error) => {
                    let _ = ready.send(Err(error));
                }
            })
            .map_err(|error| SessionError::Connection(format!("couldn't start its thread: {error}")))?;
        let capabilities = answer.recv().map_err(|_| SessionError::Stopped)??;
        Ok(Self {
            commands,
            wake,
            capabilities,
        })
    }

    pub fn capabilities(&self) -> Capabilities {
        self.capabilities
    }

    /// The focused field, as the compositor has described it by now. Nothing is known about a
    /// field without an input method: the default target.
    pub fn target(&self) -> InsertionTarget {
        let (reply, answer) = mpsc::channel();
        if !self.send(Command::Target(reply)) {
            return InsertionTarget::default();
        }
        answer.recv_timeout(TARGET_TIMEOUT).unwrap_or_else(|error| {
            tracing::warn!("The Wayland session didn't say what has focus: {error}");
            InsertionTarget::default()
        })
    }

    /// A dictation is on its way. If it will be pasted, what the clipboard holds is saved now, so
    /// the paste needn't wait for it; a copy made in between is noticed, and saved at the paste.
    pub fn prepare(&self) {
        self.send(Command::Prepare);
    }

    /// Types `text` into the focused field, then calls `done` from the session's thread.
    /// Insertions run one at a time, in order.
    pub fn insert(&self, text: String, done: impl FnOnce(Result<Inserted, SessionError>) + Send + 'static) {
        // A failed send drops the command, and with it `done`, which then reports the stop.
        self.send(Command::Insert {
            text,
            done: Done(Some(Box::new(done))),
        });
    }

    /// Puts `text` on the clipboard, as copying it in an app would.
    pub fn copy(&self, text: String) {
        self.send(Command::Copy(text));
    }

    /// Pastes with `configuration` from the next paste on.
    pub fn set_insertion(&self, configuration: InsertionConfiguration) {
        self.send(Command::Configure(configuration));
    }

    /// Shows the dictation panel with `content`, or hides it.
    pub fn show_panel(&self, content: Option<PanelContent>) {
        self.send(Command::Panel(content));
    }

    fn send(&self, command: Command) -> bool {
        if self.commands.send(command).is_err() {
            return false;
        }
        // A full pipe has the thread's attention already.
        let _ = rustix::io::write(&self.wake, &[1]);
        true
    }
}

#[derive(Debug)]
pub enum SessionError {
    /// No Wayland session to connect to.
    NoDisplay(String),
    /// The compositor lacks a protocol typing needs.
    Unsupported { protocol: &'static str },
    /// The Wayland connection failed or was closed.
    Connection(String),
    /// The session's thread has ended after an earlier error.
    Stopped,
    /// The focused field is a password field, so nothing was typed.
    SecureField,
    /// Focus left the field partway through a long text.
    FocusLost { characters: usize },
}

impl std::fmt::Display for SessionError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NoDisplay(detail) => write!(
                formatter,
                "no Wayland session to type into ({detail}); run it in the desktop session, \
                 where WAYLAND_DISPLAY is set"
            ),
            Self::Unsupported { protocol } => write!(
                formatter,
                "this desktop doesn't let apps {protocol}, which typing dictated text needs; \
                 COSMIC, KDE Plasma, Sway and Hyprland do, GNOME doesn't"
            ),
            Self::Connection(detail) => write!(formatter, "the Wayland connection failed: {detail}"),
            Self::Stopped => formatter.write_str("the Wayland session has stopped after an earlier error"),
            Self::SecureField => formatter.write_str("the focused field is a password field"),
            Self::FocusLost { characters } => write!(
                formatter,
                "the field lost focus after {characters} characters; the rest wasn't typed"
            ),
        }
    }
}

impl std::error::Error for SessionError {}
