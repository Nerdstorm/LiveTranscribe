//! The session's thread: one Wayland connection, and a loop that waits on it, on the handle's
//! commands, and on whatever is due next: the clipboard going back after a paste, the next piece
//! of a long text, the panel's next frame.

use std::collections::VecDeque;
use std::os::fd::OwnedFd;
use std::sync::mpsc::{Receiver, TryRecvError};
use std::sync::{Mutex, MutexGuard, PoisonError};
use std::time::Instant;

use rustix::event::{PollFd, PollFlags, Timespec, poll};
use rustix::io::Errno;
use wayland_client::backend::WaylandError;
use wayland_client::globals::{GlobalListContents, registry_queue_init};
use wayland_client::protocol::wl_registry::{self, WlRegistry};
use wayland_client::protocol::wl_seat::WlSeat;
use wayland_client::{Connection, Dispatch, EventQueue, QueueHandle};

use crate::input_method::{InputMethod, InputMethodState};
use crate::panel::{Panel, PanelState};
use crate::paste::{ClipboardState, Paster};
use crate::session::{Capabilities, Command, Done, SessionConfiguration, SessionError, SessionEvent};

/// What the compositor has told the session, by the part it concerns.
#[derive(Default)]
pub(crate) struct State {
    pub(crate) clipboard: ClipboardState,
    pub(crate) input_method: InputMethodState,
    pub(crate) panel: PanelState,
}

/// The connection's queue, and what its events have said.
pub(crate) struct Wayland {
    pub(crate) queue: EventQueue<State>,
    pub(crate) handle: QueueHandle<State>,
    pub(crate) state: State,
}

impl Wayland {
    /// Sends what is queued, and handles what the compositor sent until it has handled it.
    pub(crate) fn roundtrip(&mut self) -> Result<(), String> {
        self.queue
            .roundtrip(&mut self.state)
            .map(drop)
            .map_err(|error| error.to_string())
    }

    pub(crate) fn flush(&self) -> Result<(), String> {
        self.queue.flush().map_err(|error| error.to_string())
    }
}

pub(crate) struct Session {
    wayland: Wayland,
    paster: Paster,
    input_method: Option<InputMethod>,
    panel: Option<Panel>,
    /// Text waiting for the insertion before it.
    waiting: VecDeque<(String, Done)>,
    events: Box<dyn Fn(SessionEvent) + Send>,
}

impl Session {
    pub(crate) fn connect(
        configuration: SessionConfiguration,
        events: Box<dyn Fn(SessionEvent) + Send>,
    ) -> Result<Self, SessionError> {
        let connection = Connection::connect_to_env().map_err(|error| SessionError::NoDisplay(error.to_string()))?;
        let (globals, queue) =
            registry_queue_init::<State>(&connection).map_err(|error| SessionError::Connection(error.to_string()))?;
        let handle = queue.handle();
        let seat: WlSeat = globals
            .bind(&handle, 1..=5, ())
            .map_err(|_| SessionError::Connection("the compositor has no seat".to_owned()))?;
        let paster = Paster::bind(&globals, &seat, &handle, configuration.insertion)?;
        let input_method = InputMethod::bind(&globals, &seat, &handle);
        let panel = configuration
            .panel
            .and_then(|panel| Panel::bind(&globals, &seat, &handle, panel));
        let mut wayland = Wayland {
            queue,
            handle,
            state: State::default(),
        };
        // Brings the clipboard's offer, the seat's pointer, and whether the input method is ours.
        wayland.roundtrip().map_err(SessionError::Connection)?;
        let mut session = Self {
            wayland,
            paster,
            input_method,
            panel,
            waiting: VecDeque::new(),
            events,
        };
        session.drop_unavailable_input_method();
        let capabilities = session.capabilities();
        tracing::info!(
            "Connected to the Wayland compositor. Dictated text {}; the panel shows {}",
            if capabilities.input_method {
                "goes in through the input method where a field takes one, and is pasted elsewhere"
            } else {
                "is pasted"
            },
            match (session.panel.is_some(), capabilities.input_method, capabilities.overlay) {
                (false, _, _) => "nowhere",
                (true, true, true) => "at the text cursor, or at the bottom of the screen",
                (true, true, false) => "only at the text cursor",
                (true, false, true) => "at the bottom of the screen",
                (true, false, false) => "nowhere: this desktop has neither input-method-v2 nor wlr-layer-shell",
            }
        );
        Ok(session)
    }

    pub(crate) fn capabilities(&self) -> Capabilities {
        Capabilities {
            input_method: self.input_method.is_some(),
            overlay: self.panel.as_ref().is_some_and(Panel::has_overlay),
        }
    }

    pub(crate) fn run(&mut self, commands: &Receiver<Command>, wake: OwnedFd) {
        let mut wake = Some(wake);
        let error = loop {
            match self.turn(commands, &mut wake) {
                Ok(true) => {}
                Ok(false) => return,
                Err(error) => break error,
            }
        };
        tracing::error!("The Wayland session stopped: {error}");
        self.paster.abandon(&error);
        if let Some(input_method) = &mut self.input_method {
            input_method.abandon(&error);
        }
        for (_, done) in self.waiting.drain(..) {
            done.finish(Err(SessionError::Connection(error.clone())));
        }
        // Commands sent from now on are dropped with the receiver, and report the stop.
    }

    /// Handles what has arrived, then waits for the compositor, a command or whatever is due
    /// next. Returns false once the handle is gone and no text is left to type.
    fn turn(&mut self, commands: &Receiver<Command>, wake: &mut Option<OwnedFd>) -> Result<bool, String> {
        self.wayland
            .queue
            .dispatch_pending(&mut self.wayland.state)
            .map_err(|error| error.to_string())?;
        if self.wayland.state.clipboard.finished {
            return Err("the compositor withdrew clipboard access".to_owned());
        }
        self.drop_unavailable_input_method();
        if wake.is_some() {
            loop {
                match commands.try_recv() {
                    Ok(command) => self.handle(command)?,
                    Err(TryRecvError::Empty) => break,
                    Err(TryRecvError::Disconnected) => {
                        *wake = None;
                        break;
                    }
                }
            }
        }
        let now = Instant::now();
        self.paster.advance(&mut self.wayland, now)?;
        if let Some(input_method) = &mut self.input_method {
            input_method.advance(&mut self.wayland, now)?;
        }
        if !self.is_inserting()
            && let Some((text, done)) = self.waiting.pop_front()
        {
            self.start_insertion(text, done)?;
        }
        if let Some(panel) = &mut self.panel {
            let focused = self
                .input_method
                .as_ref()
                .filter(|_| self.wayland.state.input_method.is_active())
                .map(InputMethod::object);
            if let Some(event) = panel.update(&mut self.wayland, focused, now) {
                (self.events)(event);
            }
        }
        if wake.is_none() && !self.is_inserting() && self.waiting.is_empty() {
            return Ok(false);
        }
        self.wayland.flush()?;

        let Some(guard) = self.wayland.queue.prepare_read() else {
            // Events are queued already.
            return Ok(true);
        };
        let deadline = [
            self.paster.deadline(&self.wayland.state.clipboard),
            self.input_method.as_ref().and_then(InputMethod::deadline),
            self.panel
                .as_ref()
                .and_then(|panel| panel.deadline(&self.wayland.state.panel)),
        ]
        .into_iter()
        .flatten()
        .min();
        let timeout = deadline
            .map(|deadline| Timespec::try_from(deadline.saturating_duration_since(Instant::now())))
            .transpose()
            .map_err(|error| error.to_string())?;
        let (readable, woken) = {
            let mut fds = vec![PollFd::from_borrowed_fd(guard.connection_fd(), PollFlags::IN)];
            if let Some(wake) = wake.as_ref() {
                fds.push(PollFd::new(wake, PollFlags::IN));
            }
            match poll(&mut fds, timeout.as_ref()) {
                Ok(_) | Err(Errno::INTR) => {}
                Err(error) => return Err(format!("couldn't wait for the compositor: {error}")),
            }
            let readable = fds[0]
                .revents()
                .intersects(PollFlags::IN | PollFlags::ERR | PollFlags::HUP);
            (readable, fds.get(1).is_some_and(|fd| !fd.revents().is_empty()))
        };
        if readable {
            match guard.read() {
                Ok(_) => {}
                Err(WaylandError::Io(error)) if error.kind() == std::io::ErrorKind::WouldBlock => {}
                Err(error) => return Err(error.to_string()),
            }
        } else {
            drop(guard);
        }
        if woken && let Some(wake) = wake.as_ref() {
            let mut drained = [0_u8; 64];
            while matches!(rustix::io::read(wake, &mut drained), Ok(count) if count > 0) {}
        }
        Ok(true)
    }

    fn handle(&mut self, command: Command) -> Result<(), String> {
        match command {
            Command::Target(reply) => {
                // Whatever the compositor has said about focus by now counts.
                self.wayland.roundtrip()?;
                let _ = reply.send(self.wayland.state.input_method.target());
            }
            Command::Prepare => {
                // Text for a field with an input method goes straight in: only a paste needs the
                // clipboard saved.
                if !self.wayland.state.input_method.is_active() {
                    self.paster.prepare(&mut self.wayland)?;
                }
            }
            Command::Insert { text, done } => self.waiting.push_back((text, done)),
            Command::Copy(text) => self.paster.copy(&mut self.wayland, &text)?,
            Command::Panel(content) => {
                if let Some(panel) = &mut self.panel {
                    panel.show(content);
                }
            }
        }
        Ok(())
    }

    fn start_insertion(&mut self, text: String, done: Done) -> Result<(), String> {
        // The text goes wherever focus is now.
        self.wayland.roundtrip()?;
        match &mut self.input_method {
            Some(input_method) if self.wayland.state.input_method.is_active() => {
                input_method.start(&mut self.wayland, text, done)
            }
            _ => self.paster.start(&mut self.wayland, text, done),
        }
    }

    fn is_inserting(&self) -> bool {
        self.paster.is_busy() || self.input_method.as_ref().is_some_and(InputMethod::is_busy)
    }

    /// Another input method has the seat, or the seat has gone: this one is inert from now on.
    fn drop_unavailable_input_method(&mut self) {
        if self.wayland.state.input_method.unavailable
            && let Some(input_method) = self.input_method.take()
        {
            tracing::warn!(
                "Another input method (IBus or Fcitx?) has this seat, so dictated text is pasted, \
                 and the panel shows at the bottom of the screen"
            );
            input_method.destroy();
        }
    }
}

pub(crate) fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

impl Dispatch<WlRegistry, GlobalListContents> for State {
    fn event(
        _: &mut Self,
        _: &WlRegistry,
        _: wl_registry::Event,
        _: &GlobalListContents,
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
    }
}
