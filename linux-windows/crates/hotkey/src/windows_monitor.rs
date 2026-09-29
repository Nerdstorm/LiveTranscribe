//! Watching the keyboard on Windows: a low-level keyboard hook (WH_KEYBOARD_LL, through willhook),
//! which sees each key typed in the session whichever app has the focus, and takes none of it. It
//! needs no permission, but it doesn't say which keyboard a key came from, so every keyboard is
//! one; nor does it see keys typed into an app running as administrator, as Windows keeps apps
//! from reading those.
//!
//! Keys other programs type (injected ones, such as the text dictation types) are left out, as the
//! Linux monitor only reads keyboards. Key codes stay in this process, and only the hotkey's
//! meaning leaves it.

use std::collections::HashSet;
use std::sync::{Arc, Mutex, PoisonError};
use std::thread;

use willhook::{Hook, InputEvent, IsEventInjected, KeyPress, KeyboardKey};

use crate::key_names::code_for_virtual_key;
use crate::key_tracker::{HotkeyEvent, KeyState, KeyTracker, UnusableHotkey};

/// What the monitor calls the keyboard: all of them, as one.
const KEYBOARD_NAME: &str = "every keyboard";

/// The keyboard being watched: on Windows, every keyboard as one.
#[derive(Clone, Debug)]
pub struct Keyboard {
    pub id: u64,
    pub name: String,
}

/// Something that happened on the keyboard.
#[derive(Clone, Copy, Debug)]
pub enum KeyboardEvent<'a> {
    Key {
        keyboard: &'a Keyboard,
        code: u16,
        state: KeyState,
    },
}

#[derive(Debug)]
pub enum MonitorError {
    /// The hotkey can't be used.
    Hotkey(UnusableHotkey),
    /// The keyboard hook couldn't be put in place.
    Hook,
}

impl std::fmt::Display for MonitorError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Hotkey(reason) => write!(formatter, "that hotkey can't be used: {reason}"),
            Self::Hook => formatter.write_str("the keyboard can't be watched: Windows didn't take the keyboard hook"),
        }
    }
}

impl std::error::Error for MonitorError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Hotkey(reason) => Some(reason),
            Self::Hook => None,
        }
    }
}

/// Watches the keyboard, calling `on_event` for each key from the hook's reading thread, in the
/// order typed. Returns the keyboard, one for all of them.
///
/// Every key is reported, whatever `codes` names: the hook can't be told to leave keys out, as
/// the Linux monitor leaves out keyboards without them. The watching never stops: it lasts as long
/// as the process.
pub fn watch_keyboards<F>(codes: Vec<u16>, on_event: F) -> Result<Vec<Keyboard>, MonitorError>
where
    F: Fn(KeyboardEvent<'_>) + Send + Sync + 'static,
{
    let _ = codes;
    let keyboard = start_watching(Box::new(move |keyboard, virtual_key, state| {
        let code = code_for_virtual_key(virtual_key, None);
        on_event(KeyboardEvent::Key { keyboard, code, state });
    }))?;
    Ok(vec![keyboard])
}

/// Watches the keyboard for `hotkey`, an input event code, and Esc, delivering what the keys mean
/// for dictation to `sink`, in the order they happened. Returns the keyboard, one for all of them,
/// and a handle that changes the hotkey, or pauses it, while the watching goes on.
pub fn watch_hotkey<F>(hotkey: u16, sink: F) -> Result<(HotkeyWatch, Vec<Keyboard>), MonitorError>
where
    F: Fn(HotkeyEvent) + Send + Sync + 'static,
{
    let tracker = Arc::new(Mutex::new(KeyTracker::new(hotkey).map_err(MonitorError::Hotkey)?));
    let tracking = Arc::clone(&tracker);
    let keyboard = start_watching(Box::new(move |keyboard, virtual_key, state| {
        // Events are delivered under the lock, so they arrive in the order they were tracked.
        let mut tracker = lock(&tracking);
        let code = code_for_virtual_key(virtual_key, Some(tracker.hotkey()));
        if let Some(meaning) = tracker.key(keyboard.id, code, state) {
            sink(meaning);
        }
    }))?;
    Ok((HotkeyWatch { tracker }, vec![keyboard]))
}

/// Changes what [`watch_hotkey`] watches for. Clones control the same watch.
#[derive(Clone)]
pub struct HotkeyWatch {
    tracker: Arc<Mutex<KeyTracker>>,
}

impl HotkeyWatch {
    /// Watches for `hotkey` from now on (see [`KeyTracker::set_hotkey`]).
    pub fn set_hotkey(&self, hotkey: u16) -> Result<(), UnusableHotkey> {
        lock(&self.tracker).set_hotkey(hotkey)
    }

    /// Pauses the hotkey and Esc, or resumes them (see [`KeyTracker::set_paused`]).
    pub fn set_paused(&self, paused: bool) {
        lock(&self.tracker).set_paused(paused);
    }

    pub fn hotkey(&self) -> u16 {
        lock(&self.tracker).hotkey()
    }
}

/// Called with the keyboard, a key's virtual-key code and what it did.
type KeyHandler = Box<dyn Fn(&Keyboard, u16, KeyState) + Send>;

/// Puts the hook in place and reads its events on a thread of their own.
fn start_watching(on_key: KeyHandler) -> Result<Keyboard, MonitorError> {
    // None when the process has a hook already, which it only takes once.
    let hook = willhook::keyboard_hook().ok_or(MonitorError::Hook)?;
    let keyboard = Keyboard {
        id: 1,
        name: KEYBOARD_NAME.to_owned(),
    };
    let reading = keyboard.clone();
    thread::Builder::new()
        .name("keyboard-hook".to_owned())
        .spawn(move || read_keys(&hook, &reading, &on_key))
        .map_err(|error| {
            tracing::error!("Couldn't start reading the keyboard hook: {error}");
            MonitorError::Hook
        })?;
    tracing::info!("Watching the keyboard through a low-level hook");
    Ok(keyboard)
}

/// Reads the hook's events for as long as the process runs. The hook goes when `hook` does, which
/// is never: this thread keeps it.
fn read_keys(hook: &Hook, keyboard: &Keyboard, on_key: &KeyHandler) {
    let mut held = HeldKeys::default();
    while let Ok(event) = hook.recv() {
        let InputEvent::Keyboard(event) = event else {
            continue;
        };
        if event.is_injected != Some(IsEventInjected::NotInjected) {
            continue;
        }
        let Some(virtual_key) = event.key.and_then(virtual_key) else {
            continue;
        };
        let down = match event.pressed {
            KeyPress::Down(_) => true,
            KeyPress::Up(_) => false,
            KeyPress::Other(_) => continue,
        };
        on_key(keyboard, virtual_key, held.state(virtual_key, down));
    }
    tracing::warn!("The keyboard hook stopped");
}

/// The keys held down, to tell a key's first press from the keyboard repeating it: the hook
/// reports both as a key going down.
#[derive(Default)]
struct HeldKeys(HashSet<u16>);

impl HeldKeys {
    fn state(&mut self, virtual_key: u16, down: bool) -> KeyState {
        if !down {
            self.0.remove(&virtual_key);
            KeyState::Released
        } else if self.0.insert(virtual_key) {
            KeyState::Pressed
        } else {
            KeyState::Repeated
        }
    }
}

/// The virtual-key code willhook read `key` from.
fn virtual_key(key: KeyboardKey) -> Option<u16> {
    use KeyboardKey::*;
    let code: u32 = match key {
        BackSpace => 0x08,
        Tab => 0x09,
        Enter => 0x0D,
        Escape => 0x1B,
        Space => 0x20,
        PageUp => 0x21,
        PageDown => 0x22,
        Home => 0x24,
        ArrowLeft => 0x25,
        ArrowUp => 0x26,
        ArrowRight => 0x27,
        ArrowDown => 0x28,
        Print => 0x2A,
        PrintScreen => 0x2C,
        Insert => 0x2D,
        Delete => 0x2E,
        Number0 => 0x30,
        Number1 => 0x31,
        Number2 => 0x32,
        Number3 => 0x33,
        Number4 => 0x34,
        Number5 => 0x35,
        Number6 => 0x36,
        Number7 => 0x37,
        Number8 => 0x38,
        Number9 => 0x39,
        A => 0x41,
        B => 0x42,
        C => 0x43,
        D => 0x44,
        E => 0x45,
        F => 0x46,
        G => 0x47,
        H => 0x48,
        I => 0x49,
        J => 0x4A,
        K => 0x4B,
        L => 0x4C,
        M => 0x4D,
        N => 0x4E,
        O => 0x4F,
        P => 0x50,
        Q => 0x51,
        R => 0x52,
        S => 0x53,
        T => 0x54,
        U => 0x55,
        V => 0x56,
        W => 0x57,
        X => 0x58,
        Y => 0x59,
        Z => 0x5A,
        LeftWindows => 0x5B,
        RightWindows => 0x5C,
        Numpad0 => 0x60,
        Numpad1 => 0x61,
        Numpad2 => 0x62,
        Numpad3 => 0x63,
        Numpad4 => 0x64,
        Numpad5 => 0x65,
        Numpad6 => 0x66,
        Numpad7 => 0x67,
        Numpad8 => 0x68,
        Numpad9 => 0x69,
        Multiply => 0x6A,
        Add => 0x6B,
        Separator => 0x6C,
        Subtract => 0x6D,
        Decimal => 0x6E,
        Divide => 0x6F,
        F1 => 0x70,
        F2 => 0x71,
        F3 => 0x72,
        F4 => 0x73,
        F5 => 0x74,
        F6 => 0x75,
        F7 => 0x76,
        F8 => 0x77,
        F9 => 0x78,
        F10 => 0x79,
        F11 => 0x7A,
        F12 => 0x7B,
        F13 => 0x7C,
        F14 => 0x7D,
        F15 => 0x7E,
        F16 => 0x7F,
        F17 => 0x80,
        F18 => 0x81,
        F19 => 0x82,
        F20 => 0x83,
        F21 => 0x84,
        F22 => 0x85,
        F23 => 0x86,
        F24 => 0x87,
        NumLock => 0x90,
        ScrollLock => 0x91,
        CapsLock => 0x14,
        LeftShift => 0xA0,
        RightShift => 0xA1,
        LeftControl => 0xA2,
        RightControl => 0xA3,
        LeftAlt => 0xA4,
        RightAlt => 0xA5,
        SemiColon => 0xBA,
        Comma => 0xBC,
        Period => 0xBE,
        Slash => 0xBF,
        Grave => 0xC0,
        LeftBrace => 0xDB,
        BackwardSlash => 0xDC,
        RightBrace => 0xDD,
        Apostrophe => 0xDE,
        Other(code) => code,
        InvalidKeyCodeReceived => return None,
    };
    u16::try_from(code).ok()
}

fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_key_going_down_again_while_held_is_the_keyboard_repeating_it() {
        let mut held = HeldKeys::default();
        assert_eq!(held.state(0xA3, true), KeyState::Pressed);
        assert_eq!(held.state(0xA3, true), KeyState::Repeated);
        assert_eq!(held.state(0x41, true), KeyState::Pressed, "another key");
        assert_eq!(held.state(0xA3, false), KeyState::Released);
        assert_eq!(held.state(0xA3, true), KeyState::Pressed);
        assert_eq!(held.state(0x1B, false), KeyState::Released, "a release never seen down");
    }

    #[test]
    fn keys_read_back_as_the_codes_they_were_read_from() {
        assert_eq!(virtual_key(KeyboardKey::RightControl), Some(0xA3));
        assert_eq!(virtual_key(KeyboardKey::Escape), Some(0x1B));
        assert_eq!(
            virtual_key(KeyboardKey::Other(0x23)),
            Some(0x23),
            "End, which willhook doesn't name"
        );
        assert_eq!(virtual_key(KeyboardKey::InvalidKeyCodeReceived), None);
        // willhook's own reading of each code, back to the code.
        for code in 1..=0xFE_u32 {
            assert_eq!(
                virtual_key(KeyboardKey::from(code)),
                u16::try_from(code).ok(),
                "{code:#x}"
            );
        }
    }
}
