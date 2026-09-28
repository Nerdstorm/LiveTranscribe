//! Pasting, for fields without an input method: ext-data-control-v1 reads, sets and puts back the
//! clipboard, and a virtual keyboard (zwp-virtual-keyboard-v1) types Ctrl+V.
//!
//! The session's thread serves the clipboard this app sets: the dictated text while it is pasted,
//! then what the clipboard held before, or the text itself when nothing took it. **Quitting the
//! app therefore empties a clipboard it set**; a later copy in another app is unaffected.
//!
//! The virtual keyboard types from a keymap holding only V, as wtype does, rather than from a copy
//! of the user's. The compositor switches the focused app to that keymap for the shortcut and back
//! to the real one, with the real modifiers and layout, at the next key the user presses. With a
//! copy of the user's keymap nothing would switch back (smithay, COSMIC's compositor library,
//! compares keymaps by content), and the app would keep the virtual keyboard's idea of Caps Lock,
//! Num Lock and the layout. Modifier masks are Wayland's real modifiers, whose bits are fixed:
//! Control is 1 << 2.

use std::fs::File;
use std::io::Write;
use std::os::fd::{AsFd, OwnedFd};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use lt_insertion::{ClipboardContents, Inserted, InsertionConfiguration, InsertionMethod, holds_data, is_text};
use rustix::event::{PollFd, PollFlags, Timespec, poll};
use rustix::fs::{MemfdFlags, OFlags, fcntl_getfl, fcntl_setfl, memfd_create};
use rustix::io::Errno;
use rustix::pipe::{PipeFlags, pipe_with};
use wayland_client::globals::GlobalList;
use wayland_client::protocol::wl_seat::WlSeat;
use wayland_client::{Connection, Dispatch, Proxy, QueueHandle, delegate_noop, event_created_child};
use wayland_protocols::ext::data_control::v1::client::ext_data_control_device_v1::{self, ExtDataControlDeviceV1};
use wayland_protocols::ext::data_control::v1::client::ext_data_control_manager_v1::ExtDataControlManagerV1;
use wayland_protocols::ext::data_control::v1::client::ext_data_control_offer_v1::{self, ExtDataControlOfferV1};
use wayland_protocols::ext::data_control::v1::client::ext_data_control_source_v1::{self, ExtDataControlSourceV1};
use wayland_protocols_misc::zwp_virtual_keyboard_v1::client::zwp_virtual_keyboard_manager_v1::ZwpVirtualKeyboardManagerV1;
use wayland_protocols_misc::zwp_virtual_keyboard_v1::client::zwp_virtual_keyboard_v1::ZwpVirtualKeyboardV1;

use crate::event_loop::{State, Wayland, lock};
use crate::session::{Done, SessionError};

/// The keymap the virtual keyboard types from: V alone, on evdev key 1 (XKB keycode 9).
const PASTE_KEYMAP: &str = "xkb_keymap {
xkb_keycodes \"live-transcribe\" { minimum = 8; maximum = 255; <K1> = 9; };
xkb_types \"live-transcribe\" { include \"complete\" };
xkb_compatibility \"live-transcribe\" { include \"complete\" };
xkb_symbols \"live-transcribe\" { key <K1> { [ v ] }; };
};
";
const V_KEY: u32 = 1;
const CONTROL_MASK: u32 = 1 << 2;
const KEYMAP_FORMAT_XKB_V1: u32 = 1;
const KEY_RELEASED: u32 = 0;
const KEY_PRESSED: u32 = 1;

/// Saving what the clipboard holds: at most this much in all, each type given at most
/// `TYPE_READ_TIMEOUT` and all of them `SAVE_TIMEOUT`. What doesn't fit is left out of the
/// clipboard put back.
const SAVE_LIMIT_BYTES: usize = 64 << 20;
const TYPE_READ_TIMEOUT: Duration = Duration::from_millis(500);
const SAVE_TIMEOUT: Duration = Duration::from_secs(2);

/// What the compositor has said about the clipboard.
#[derive(Default)]
pub(crate) struct ClipboardState {
    /// The clipboard's offer; `None` when it is empty.
    selection: Option<ExtDataControlOfferV1>,
    /// Counts selection changes, this app's included.
    generation: u64,
    /// The source this app made the clipboard, until another app replaces it.
    own_selection: Option<ExtDataControlSourceV1>,
    /// The paste's source, and when an app first read it.
    paste_source: Option<ExtDataControlSourceV1>,
    paste_read_at: Option<Instant>,
    /// The compositor withdrew clipboard access.
    pub(crate) finished: bool,
}

/// What the clipboard held when it was saved.
enum Saved {
    /// Nothing: it is emptied again.
    Empty,
    Contents(Arc<ClipboardContents>),
    /// It held something none of which could be read: the dictated text stays instead.
    Unreadable,
}

struct Snapshot {
    /// The selection it was saved from, as [`ClipboardState::generation`] counts them.
    generation: u64,
    saved: Saved,
}

/// A paste in progress: the text is on the clipboard and Ctrl+V was typed.
struct Paste {
    source: ExtDataControlSourceV1,
    typed_at: Instant,
    saved: Saved,
    characters: usize,
    done: Done,
}

pub(crate) struct Paster {
    manager: ExtDataControlManagerV1,
    device: ExtDataControlDeviceV1,
    keyboard: ZwpVirtualKeyboardV1,
    configuration: InsertionConfiguration,
    snapshot: Option<Snapshot>,
    paste: Option<Paste>,
    /// Key events carry milliseconds from this.
    clock: Instant,
}

impl Paster {
    /// Pastes from now on with `configuration`; a paste under way keeps its timing.
    pub(crate) fn set_configuration(&mut self, configuration: InsertionConfiguration) {
        self.configuration = configuration;
    }

    pub(crate) fn bind(
        globals: &GlobalList,
        seat: &WlSeat,
        handle: &QueueHandle<State>,
        configuration: InsertionConfiguration,
    ) -> Result<Self, SessionError> {
        let manager: ExtDataControlManagerV1 =
            globals.bind(handle, 1..=1, ()).map_err(|_| SessionError::Unsupported {
                protocol: "manage the clipboard (ext-data-control-v1)",
            })?;
        let keyboards: ZwpVirtualKeyboardManagerV1 =
            globals.bind(handle, 1..=1, ()).map_err(|_| SessionError::Unsupported {
                protocol: "type keys (zwp-virtual-keyboard-v1)",
            })?;
        let device = manager.get_data_device(seat, handle, ());
        let keyboard = keyboards.create_virtual_keyboard(seat, handle, ());
        let (keymap, size) =
            paste_keymap().map_err(|error| SessionError::Connection(format!("couldn't make the keymap: {error}")))?;
        keyboard.keymap(KEYMAP_FORMAT_XKB_V1, keymap.as_fd(), size);
        Ok(Self {
            manager,
            device,
            keyboard,
            configuration,
            snapshot: None,
            paste: None,
            clock: Instant::now(),
        })
    }

    pub(crate) fn is_busy(&self) -> bool {
        self.paste.is_some()
    }

    /// Saves what the clipboard holds now, for a paste soon after.
    pub(crate) fn prepare(&mut self, wayland: &mut Wayland) -> Result<(), String> {
        // Mid-paste the clipboard holds the text; the paste's own save stands.
        if self.paste.is_none() {
            self.snapshot = Some(self.save_clipboard(wayland)?);
        }
        Ok(())
    }

    /// Puts `text` on the clipboard and types Ctrl+V. The caller has just made a round trip.
    pub(crate) fn start(&mut self, wayland: &mut Wayland, text: String, done: Done) -> Result<(), String> {
        let characters = text.chars().count();
        if characters == 0 {
            done.finish(Ok(Inserted {
                characters,
                method: InsertionMethod::Paste,
                read: false,
                restored: false,
            }));
            return Ok(());
        }
        let clipboard = &wayland.state.clipboard;
        let saved = match self.snapshot.take() {
            Some(snapshot) if snapshot.generation == clipboard.generation && clipboard.own_selection.is_none() => {
                snapshot.saved
            }
            _ => self.save_clipboard(wayland)?.saved,
        };

        let contents = Arc::new(ClipboardContents::text(&text));
        let source = self.offer(&wayland.handle, &contents);
        self.device.set_selection(Some(&source));
        let clipboard = &mut wayland.state.clipboard;
        clipboard.own_selection = Some(source.clone());
        clipboard.paste_source = Some(source.clone());
        clipboard.paste_read_at = None;
        self.type_paste_shortcut();
        wayland.flush()?;
        self.paste = Some(Paste {
            source,
            typed_at: Instant::now(),
            saved,
            characters,
            done,
        });
        Ok(())
    }

    /// Puts `text` on the clipboard as a copy of the user's, as *Copy Last Dictation* does. It is
    /// served from memory until something else is copied; a paste in progress then leaves it be.
    pub(crate) fn copy(&mut self, wayland: &mut Wayland, text: &str) -> Result<(), String> {
        let contents = Arc::new(ClipboardContents::copied_text(text));
        let source = self.offer(&wayland.handle, &contents);
        self.device.set_selection(Some(&source));
        wayland.state.clipboard.own_selection = Some(source);
        wayland.flush()
    }

    /// When the clipboard goes back: a moment after the app read the text, or once it has had
    /// long enough to.
    pub(crate) fn deadline(&self, clipboard: &ClipboardState) -> Option<Instant> {
        let paste = self.paste.as_ref()?;
        Some(match clipboard.paste_read_at {
            Some(read_at) => read_at + self.configuration.restore_delay,
            None => paste.typed_at + self.configuration.read_timeout,
        })
    }

    /// Puts the clipboard back once the paste's deadline has passed.
    pub(crate) fn advance(&mut self, wayland: &mut Wayland, now: Instant) -> Result<(), String> {
        if self
            .deadline(&wayland.state.clipboard)
            .is_some_and(|deadline| now >= deadline)
        {
            self.put_back(wayland)?;
        }
        Ok(())
    }

    /// The session is stopping: the paste in progress fails with it.
    pub(crate) fn abandon(&mut self, error: &str) {
        if let Some(paste) = self.paste.take() {
            paste.done.finish(Err(SessionError::Connection(error.to_owned())));
        }
    }

    fn type_paste_shortcut(&self) {
        // Key times are milliseconds on any clock; they wrap like the compositor's.
        let time = (self.clock.elapsed().as_millis() & u128::from(u32::MAX)) as u32;
        self.keyboard.modifiers(CONTROL_MASK, 0, 0, 0);
        self.keyboard.key(time, V_KEY, KEY_PRESSED);
        self.keyboard.key(time, V_KEY, KEY_RELEASED);
        self.keyboard.modifiers(0, 0, 0, 0);
    }

    fn put_back(&mut self, wayland: &mut Wayland) -> Result<(), String> {
        let Some(paste) = self.paste.take() else {
            return Ok(());
        };
        let clipboard = &mut wayland.state.clipboard;
        let read = clipboard.paste_read_at.take().is_some();
        clipboard.paste_source = None;
        // Something copied since stays. So does the text when nothing read it, for the user to
        // paste, as the Mac app leaves text it could not insert.
        let still_ours = clipboard.own_selection.as_ref() == Some(&paste.source);
        let restored = read
            && still_ours
            && match &paste.saved {
                Saved::Empty => {
                    self.device.set_selection(None);
                    wayland.state.clipboard.own_selection = None;
                    true
                }
                Saved::Contents(contents) => {
                    let source = self.offer(&wayland.handle, contents);
                    self.device.set_selection(Some(&source));
                    wayland.state.clipboard.own_selection = Some(source);
                    true
                }
                Saved::Unreadable => false,
            };
        wayland.flush()?;
        tracing::info!(
            "Pasted {} characters in {} ms ({}), clipboard {}",
            paste.characters,
            paste.typed_at.elapsed().as_millis(),
            if read { "read by the app" } else { "never read" },
            match (restored, read, still_ours) {
                (true, _, _) => "put back",
                (false, false, true) => "left holding the text",
                _ => "left as it was",
            }
        );
        paste.done.finish(Ok(Inserted {
            characters: paste.characters,
            method: InsertionMethod::Paste,
            read,
            restored,
        }));
        Ok(())
    }

    /// A source offering `contents`, served from memory.
    fn offer(&self, handle: &QueueHandle<State>, contents: &Arc<ClipboardContents>) -> ExtDataControlSourceV1 {
        let source = self.manager.create_data_source(handle, Arc::clone(contents));
        for mime_type in contents.mime_types() {
            source.offer(mime_type.to_owned());
        }
        source
    }

    /// Saves what the clipboard holds now.
    fn save_clipboard(&mut self, wayland: &mut Wayland) -> Result<Snapshot, String> {
        wayland.roundtrip()?;
        let clipboard = &wayland.state.clipboard;
        let generation = clipboard.generation;
        if let Some(own) = &clipboard.own_selection {
            // This app's own clipboard: already in memory. Reading it through the compositor
            // would wait on this very thread.
            let saved = own
                .data::<Arc<ClipboardContents>>()
                .map_or(Saved::Unreadable, |contents| Saved::Contents(Arc::clone(contents)));
            return Ok(Snapshot { generation, saved });
        }
        let Some(offer) = clipboard.selection.clone() else {
            return Ok(Snapshot {
                generation,
                saved: Saved::Empty,
            });
        };
        let types = offer
            .data::<Mutex<Vec<String>>>()
            .map(|types| lock(types).clone())
            .unwrap_or_default();
        let started = Instant::now();
        let deadline = started + SAVE_TIMEOUT;
        let mut contents = ClipboardContents::default();
        for (index, mime_type) in types.iter().enumerate().filter(|(_, mime_type)| holds_data(mime_type)) {
            if Instant::now() >= deadline {
                tracing::warn!(
                    "Saving the clipboard ran out of time; {} types left out",
                    types.len() - index
                );
                break;
            }
            let limit = SAVE_LIMIT_BYTES.saturating_sub(contents.byte_count());
            let type_deadline = deadline.min(Instant::now() + TYPE_READ_TIMEOUT);
            match receive(wayland, &offer, mime_type, type_deadline, limit) {
                Ok(data) => contents.push(mime_type, data),
                Err(reason) => tracing::warn!("The clipboard's {mime_type} couldn't be saved: {reason}"),
            }
        }
        tracing::info!(
            "Saved the clipboard ({} of {} types, {} bytes) in {} ms",
            contents.mime_types().count(),
            types.len(),
            contents.byte_count(),
            started.elapsed().as_millis()
        );
        let saved = if contents.is_empty() {
            Saved::Unreadable
        } else {
            Saved::Contents(Arc::new(contents))
        };
        Ok(Snapshot { generation, saved })
    }
}

/// Reads the offer's data as `mime_type` from the app that copied it.
fn receive(
    wayland: &Wayland,
    offer: &ExtDataControlOfferV1,
    mime_type: &str,
    deadline: Instant,
    limit: usize,
) -> Result<Vec<u8>, String> {
    // Only this end waits without blocking: the other end goes to the copying app as it is.
    let (reader, writer) = pipe_with(PipeFlags::CLOEXEC).map_err(|error| error.to_string())?;
    fcntl_setfl(&reader, OFlags::NONBLOCK).map_err(|error| error.to_string())?;
    offer.receive(mime_type.to_owned(), writer.as_fd());
    // The request holds its own copy until it is sent.
    drop(writer);
    wayland.flush()?;
    let mut data = Vec::new();
    let mut buffer = vec![0_u8; 64 << 10];
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err("the app that copied it didn't send it in time".to_owned());
        }
        let timeout = Timespec::try_from(remaining).map_err(|error| error.to_string())?;
        match poll(&mut [PollFd::new(&reader, PollFlags::IN)], Some(&timeout)) {
            Ok(_) | Err(Errno::INTR) => {}
            Err(error) => return Err(error.to_string()),
        }
        match rustix::io::read(&reader, &mut buffer) {
            Ok(0) => return Ok(data),
            Ok(count) => {
                data.extend_from_slice(&buffer[..count]);
                if data.len() > limit {
                    return Err("too large to keep".to_owned());
                }
            }
            Err(Errno::AGAIN | Errno::INTR) => {}
            Err(error) => return Err(error.to_string()),
        }
    }
}

/// The paste keymap in a memory file, and its size with the terminating NUL.
fn paste_keymap() -> std::io::Result<(OwnedFd, u32)> {
    let mut file = File::from(memfd_create("live-transcribe-keymap", MemfdFlags::CLOEXEC)?);
    let mut bytes = PASTE_KEYMAP.as_bytes().to_vec();
    bytes.push(0);
    file.write_all(&bytes)?;
    let size = u32::try_from(bytes.len()).map_err(std::io::Error::other)?;
    Ok((OwnedFd::from(file), size))
}

/// Writes clipboard data to the app that asked for it, on a thread of its own: the app may read
/// slowly, or never.
fn serve(data: Option<Arc<[u8]>>, fd: OwnedFd) {
    // Without data the descriptor is closed at once: the app reads nothing.
    let Some(data) = data else { return };
    let spawned = thread::Builder::new().name("clipboard-send".to_owned()).spawn(move || {
        // The app chose the pipe's flags; a blocking write can't stop partway.
        if let Ok(flags) = fcntl_getfl(&fd) {
            let _ = fcntl_setfl(&fd, flags - OFlags::NONBLOCK);
        }
        if let Err(error) = File::from(fd).write_all(&data) {
            tracing::debug!("An app stopped reading the clipboard early: {error}");
        }
    });
    if let Err(error) = spawned {
        tracing::warn!("Couldn't send the clipboard to an app: {error}");
    }
}

delegate_noop!(State: ExtDataControlManagerV1);
delegate_noop!(State: ZwpVirtualKeyboardManagerV1);
delegate_noop!(State: ZwpVirtualKeyboardV1);

impl Dispatch<ExtDataControlDeviceV1, ()> for State {
    fn event(
        state: &mut Self,
        _: &ExtDataControlDeviceV1,
        event: ext_data_control_device_v1::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        let clipboard = &mut state.clipboard;
        match event {
            ext_data_control_device_v1::Event::Selection { id } => {
                if let Some(previous) = std::mem::replace(&mut clipboard.selection, id) {
                    previous.destroy();
                }
                clipboard.generation += 1;
            }
            // The middle-click selection is left alone.
            ext_data_control_device_v1::Event::PrimarySelection { id: Some(offer) } => offer.destroy(),
            ext_data_control_device_v1::Event::Finished => clipboard.finished = true,
            // An offer's types arrive on the offer itself.
            _ => {}
        }
    }

    event_created_child!(State, ExtDataControlDeviceV1, [
        ext_data_control_device_v1::EVT_DATA_OFFER_OPCODE => (ExtDataControlOfferV1, Mutex::new(Vec::new())),
    ]);
}

impl Dispatch<ExtDataControlOfferV1, Mutex<Vec<String>>> for State {
    fn event(
        _: &mut Self,
        _: &ExtDataControlOfferV1,
        event: ext_data_control_offer_v1::Event,
        types: &Mutex<Vec<String>>,
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        if let ext_data_control_offer_v1::Event::Offer { mime_type } = event {
            lock(types).push(mime_type);
        }
    }
}

impl Dispatch<ExtDataControlSourceV1, Arc<ClipboardContents>> for State {
    fn event(
        state: &mut Self,
        source: &ExtDataControlSourceV1,
        event: ext_data_control_source_v1::Event,
        contents: &Arc<ClipboardContents>,
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        let clipboard = &mut state.clipboard;
        match event {
            ext_data_control_source_v1::Event::Send { mime_type, fd } => {
                // A clipboard history that honours the hint reads only that: it is not the paste.
                if clipboard.paste_source.as_ref() == Some(source)
                    && clipboard.paste_read_at.is_none()
                    && is_text(&mime_type)
                {
                    clipboard.paste_read_at = Some(Instant::now());
                }
                serve(contents.get(&mime_type), fd);
            }
            ext_data_control_source_v1::Event::Cancelled => {
                if clipboard.own_selection.as_ref() == Some(source) {
                    clipboard.own_selection = None;
                }
                source.destroy();
            }
            _ => {}
        }
    }
}
