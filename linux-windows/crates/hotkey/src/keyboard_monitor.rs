//! Watching the keyboards on Linux: each /dev/input/event* device that has the keys asked for,
//! read with evdev on a thread of its own, and /dev/input scanned again every two seconds for
//! keyboards plugged in later.
//!
//! Reading a keyboard needs read access to its device node, which belongs to root and the `input`
//! group. The deb and rpm packages' udev rule, like the setup kit's, grants it to the user logged in
//! at the machine (`TAG+="uaccess"`), which also reaches a toolbox container, where the `input`
//! group doesn't.
//! Whoever can read a keyboard can read everything typed on it: key codes stay in this process,
//! and only the hotkey's meaning leaves it.

use std::collections::HashSet;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::str::FromStr;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::thread;
use std::time::Duration;

use evdev::{Device, EventSummary, KeyCode};

use crate::key_tracker::{HotkeyEvent, KeyState, KeyTracker, UnusableHotkey, codes};

const INPUT_FOLDER: &str = "/dev/input";
const RESCAN_INTERVAL: Duration = Duration::from_secs(2);
const EV_KEY: usize = 1;
/// "No such device": the keyboard was unplugged.
const ENODEV: i32 = 19;

/// A keyboard being read.
#[derive(Clone, Debug)]
pub struct Keyboard {
    /// Unique for the life of the process: a keyboard plugged in again gets a new one.
    pub id: u64,
    pub name: String,
    pub path: PathBuf,
}

/// Something that happened on a keyboard.
#[derive(Clone, Copy, Debug)]
pub enum KeyboardEvent<'a> {
    Key {
        keyboard: &'a Keyboard,
        code: u16,
        state: KeyState,
    },
    /// The keyboard was unplugged, or can no longer be read.
    Removed { keyboard: &'a Keyboard },
}

#[derive(Debug)]
pub enum MonitorError {
    /// Keyboards were found, but none could be read.
    PermissionDenied {
        paths: Vec<PathBuf>,
    },
    /// The hotkey can't be used.
    Hotkey(UnusableHotkey),
    Io {
        path: PathBuf,
        source: io::Error,
    },
}

impl std::fmt::Display for MonitorError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::PermissionDenied { paths } => {
                let paths: Vec<_> = paths.iter().map(|path| path.display().to_string()).collect();
                write!(
                    formatter,
                    "the keyboard can't be read: this user isn't allowed to read {}",
                    paths.join(", ")
                )
            }
            Self::Hotkey(reason) => write!(formatter, "that hotkey can't be used: {reason}"),
            Self::Io { path, source } => write!(formatter, "couldn't read {}: {source}", path.display()),
        }
    }
}

impl std::error::Error for MonitorError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Io { source, .. } => Some(source),
            Self::Hotkey(reason) => Some(reason),
            Self::PermissionDenied { .. } => None,
        }
    }
}

/// Watches every keyboard that has at least one of `codes`, now and plugged in later, calling
/// `on_event` for its key events from the keyboard's own thread. Returns the keyboards found
/// now; with none found, it keeps looking.
///
/// Fails when keyboards were found but none could be read. The watching never stops: it lasts as
/// long as the process.
pub fn watch_keyboards<F>(codes: Vec<u16>, on_event: F) -> Result<Vec<Keyboard>, MonitorError>
where
    F: Fn(KeyboardEvent<'_>) + Send + Sync + 'static,
{
    start_watching(codes, Box::new(on_event)).map(|(_, keyboards)| keyboards)
}

/// Watches the keyboards for `hotkey`, an input event code, and Esc, delivering what their keys
/// mean for dictation to `sink`, in the order they happened. Returns the keyboards found now, and
/// a handle that changes the hotkey, or pauses it, while the watching goes on.
pub fn watch_hotkey<F>(hotkey: u16, sink: F) -> Result<(HotkeyWatch, Vec<Keyboard>), MonitorError>
where
    F: Fn(HotkeyEvent) + Send + Sync + 'static,
{
    let tracker = Arc::new(Mutex::new(KeyTracker::new(hotkey).map_err(MonitorError::Hotkey)?));
    let tracking = Arc::clone(&tracker);
    // Every key matters (another key while the hotkey is held cancels), but only keyboards that
    // have the hotkey or Esc are worth reading.
    let (watcher, keyboards) = start_watching(
        hotkey_codes(hotkey),
        Box::new(move |event| {
            // Events are delivered under the lock, so they arrive in the order they were tracked.
            let mut tracker = lock(&tracking);
            let meaning = match event {
                KeyboardEvent::Key { keyboard, code, state } => tracker.key(keyboard.id, code, state),
                KeyboardEvent::Removed { keyboard } => tracker.device_removed(keyboard.id),
            };
            if let Some(meaning) = meaning {
                sink(meaning);
            }
        }),
    )?;
    Ok((HotkeyWatch { tracker, watcher }, keyboards))
}

/// Changes what [`watch_hotkey`] watches for. Clones control the same watch.
#[derive(Clone)]
pub struct HotkeyWatch {
    tracker: Arc<Mutex<KeyTracker>>,
    watcher: Arc<Watcher>,
}

impl HotkeyWatch {
    /// Watches for `hotkey` from now on (see [`KeyTracker::set_hotkey`]). A keyboard that has the
    /// new key but was left alone so far is read from the next scan, within two seconds.
    pub fn set_hotkey(&self, hotkey: u16) -> Result<(), UnusableHotkey> {
        lock(&self.tracker).set_hotkey(hotkey)?;
        *lock(&self.watcher.codes) = hotkey_codes(hotkey);
        Ok(())
    }

    /// Pauses the hotkey and Esc, or resumes them (see [`KeyTracker::set_paused`]).
    pub fn set_paused(&self, paused: bool) {
        lock(&self.tracker).set_paused(paused);
    }

    pub fn hotkey(&self) -> u16 {
        lock(&self.tracker).hotkey()
    }
}

fn hotkey_codes(hotkey: u16) -> Vec<u16> {
    vec![hotkey, codes::KEY_ESC]
}

fn start_watching(codes: Vec<u16>, on_event: EventHandler) -> Result<(Arc<Watcher>, Vec<Keyboard>), MonitorError> {
    let watcher = Arc::new(Watcher {
        codes: Mutex::new(codes),
        on_event,
        watched: Mutex::new(HashSet::new()),
        reported: Mutex::new(HashSet::new()),
        next_id: AtomicU64::new(1),
    });
    let found = watcher.scan().map_err(|source| MonitorError::Io {
        path: PathBuf::from(INPUT_FOLDER),
        source,
    })?;
    if found.opened.is_empty() && !found.denied.is_empty() {
        return Err(MonitorError::PermissionDenied { paths: found.denied });
    }
    if found.opened.is_empty() {
        tracing::warn!("No keyboard found yet; still looking");
    }
    let rescanning = Arc::clone(&watcher);
    thread::Builder::new()
        .name("keyboard-scan".to_owned())
        .spawn(move || {
            loop {
                thread::sleep(RESCAN_INTERVAL);
                if let Err(error) = rescanning.scan() {
                    tracing::warn!("Couldn't look for keyboards in {INPUT_FOLDER}: {error}");
                }
            }
        })
        .map_err(|source| MonitorError::Io {
            path: PathBuf::from(INPUT_FOLDER),
            source,
        })?;
    Ok((watcher, found.opened))
}

/// The input event code for a key name as linux/input-event-codes.h spells it, with or without
/// `KEY_` and in any case: `KEY_RIGHTCTRL`, `rightctrl`, `RightCtrl`.
pub fn key_code(name: &str) -> Option<u16> {
    let upper = name.trim().to_ascii_uppercase();
    let full = if upper.starts_with("KEY_") {
        upper
    } else {
        format!("KEY_{upper}")
    };
    KeyCode::from_str(&full).ok().map(|code| code.0)
}

/// The name of an input event code, such as `KEY_RIGHTCTRL`.
pub fn key_name(code: u16) -> String {
    let name = format!("{:?}", KeyCode(code));
    if name.starts_with("KEY_") || name.starts_with("BTN_") {
        name
    } else {
        format!("key {code}")
    }
}

/// A key's name as people say it, for the panel and the menu: `KEY_RIGHTCTRL` is "Right Ctrl".
pub fn display_name(code: u16) -> String {
    let name = key_name(code);
    let Some(bare) = name.strip_prefix("KEY_") else {
        return name;
    };
    // KEY_LEFT and KEY_RIGHT are arrow keys; KEY_LEFTCTRL and the like are one side's modifier.
    let (side, key) = match bare {
        "LEFT" | "RIGHT" | "UP" | "DOWN" => return format!("{} Arrow", title_case(bare)),
        _ => match (bare.strip_prefix("LEFT"), bare.strip_prefix("RIGHT")) {
            (Some(key), _) => ("Left ", key),
            (_, Some(key)) => ("Right ", key),
            _ => ("", bare),
        },
    };
    let key = match key {
        "CTRL" => "Ctrl".to_owned(),
        "META" => "Super".to_owned(),
        "CAPSLOCK" => "Caps Lock".to_owned(),
        "NUMLOCK" => "Num Lock".to_owned(),
        "SCROLLLOCK" => "Scroll Lock".to_owned(),
        "PAGEUP" => "Page Up".to_owned(),
        "PAGEDOWN" => "Page Down".to_owned(),
        "SYSRQ" => "Print Screen".to_owned(),
        "COMPOSE" => "Menu".to_owned(),
        "ESC" => "Esc".to_owned(),
        _ if key.starts_with('F') && key[1..].chars().all(|character| character.is_ascii_digit()) => key.to_owned(),
        _ => title_case(key),
    };
    format!("{side}{key}")
}

fn title_case(word: &str) -> String {
    let lower = word.to_ascii_lowercase();
    let mut characters = lower.chars();
    characters
        .next()
        .map(|first| first.to_ascii_uppercase().to_string() + characters.as_str())
        .unwrap_or_default()
}

type EventHandler = Box<dyn Fn(KeyboardEvent<'_>) + Send + Sync>;

struct Watcher {
    /// A device is read when it has at least one of these codes.
    codes: Mutex<Vec<u16>>,
    on_event: EventHandler,
    /// The device nodes being read.
    watched: Mutex<HashSet<PathBuf>>,
    /// Device nodes whose failure was logged already, so a rescan doesn't log it again.
    reported: Mutex<HashSet<PathBuf>>,
    next_id: AtomicU64,
}

#[derive(Default)]
struct Scan {
    opened: Vec<Keyboard>,
    denied: Vec<PathBuf>,
}

impl Watcher {
    /// Opens the devices not read yet that have the codes wanted.
    fn scan(self: &Arc<Self>) -> io::Result<Scan> {
        let mut scan = Scan::default();
        let mut entries: Vec<_> = fs::read_dir(INPUT_FOLDER)?
            .filter_map(Result::ok)
            .filter(|entry| entry.file_name().to_string_lossy().starts_with("event"))
            .map(|entry| entry.path())
            .collect();
        entries.sort();
        for path in entries {
            if lock(&self.watched).contains(&path) || !self.has_wanted_keys(&path) {
                continue;
            }
            match Device::open(&path) {
                Ok(device) => {
                    let keyboard = Keyboard {
                        id: self.next_id.fetch_add(1, Ordering::Relaxed),
                        name: device.name().unwrap_or("unnamed keyboard").to_owned(),
                        path: path.clone(),
                    };
                    tracing::info!("Reading {} ({})", keyboard.name, path.display());
                    lock(&self.watched).insert(path.clone());
                    lock(&self.reported).remove(&path);
                    let reader = Arc::clone(self);
                    let reading = keyboard.clone();
                    let spawned = thread::Builder::new()
                        .name(format!("keyboard-{}", keyboard.id))
                        .spawn(move || reader.read_keys(&reading, device));
                    if let Err(error) = spawned {
                        lock(&self.watched).remove(&path);
                        tracing::error!("Couldn't start reading {}: {error}", path.display());
                        continue;
                    }
                    scan.opened.push(keyboard);
                }
                Err(error) => {
                    if error.kind() == io::ErrorKind::PermissionDenied {
                        scan.denied.push(path.clone());
                    }
                    if lock(&self.reported).insert(path.clone()) {
                        tracing::warn!("Couldn't open {}: {error}", path.display());
                    }
                }
            }
        }
        Ok(scan)
    }

    /// Whether the device has key events with one of the codes wanted, from its capabilities in
    /// sysfs, which anyone may read: devices that aren't keyboards are never opened.
    fn has_wanted_keys(&self, path: &Path) -> bool {
        let Some(name) = path.file_name() else { return false };
        let capabilities = Path::new("/sys/class/input").join(name).join("device/capabilities");
        let read = |file: &str| {
            fs::read_to_string(capabilities.join(file))
                .ok()
                .and_then(|text| Bitmap::parse(&text, usize::BITS))
        };
        let (Some(events), Some(keys)) = (read("ev"), read("key")) else {
            return false;
        };
        events.contains(EV_KEY) && lock(&self.codes).iter().any(|&code| keys.contains(usize::from(code)))
    }

    fn read_keys(&self, keyboard: &Keyboard, mut device: Device) {
        loop {
            // Blocks until the keyboard has events. A queue that overflowed is read again from
            // the device's state, with made-up events for what changed meanwhile.
            match device.fetch_events() {
                Ok(events) => {
                    for event in events {
                        if let EventSummary::Key(_, code, value) = event.destructure()
                            && let Some(state) = KeyState::from_value(value)
                        {
                            (self.on_event)(KeyboardEvent::Key {
                                keyboard,
                                code: code.0,
                                state,
                            });
                        }
                    }
                }
                Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
                Err(error) => {
                    // Unplugged, or something worth a warning, once.
                    if error.raw_os_error() == Some(ENODEV) {
                        tracing::info!("{} was removed", keyboard.name);
                    } else if lock(&self.reported).insert(keyboard.path.clone()) {
                        tracing::warn!("Stopped reading {}: {error}", keyboard.name);
                    }
                    break;
                }
            }
        }
        lock(&self.watched).remove(&keyboard.path);
        (self.on_event)(KeyboardEvent::Removed { keyboard });
    }
}

fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

/// A capability bitmap as sysfs prints it: hexadecimal words the size of the kernel's `long`,
/// the most significant first.
#[derive(Debug, PartialEq, Eq)]
struct Bitmap {
    /// Least significant first.
    words: Vec<u64>,
    word_bits: u32,
}

impl Bitmap {
    fn parse(text: &str, word_bits: u32) -> Option<Self> {
        let mut words = text
            .split_whitespace()
            .map(|word| u64::from_str_radix(word, 16).ok())
            .collect::<Option<Vec<_>>>()?;
        words.reverse();
        Some(Self { words, word_bits })
    }

    fn contains(&self, bit: usize) -> bool {
        let bits = self.word_bits as usize;
        self.words
            .get(bit / bits)
            .is_some_and(|word| word >> (bit % bits) & 1 == 1)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A laptop's built-in keyboard (AT Translated Set 2 keyboard), from sysfs.
    const LAPTOP_KEYS: &str = "402000007 ff803078f800d001 feffffdfffcfffff fffffffffffffffe\n";

    #[test]
    fn keys_are_named_as_people_say_them() {
        let name = |key: &str| display_name(key_code(key).expect("a key"));
        assert_eq!(name("KEY_RIGHTCTRL"), "Right Ctrl");
        assert_eq!(name("KEY_LEFTALT"), "Left Alt");
        assert_eq!(name("KEY_RIGHTMETA"), "Right Super");
        assert_eq!(name("KEY_CAPSLOCK"), "Caps Lock");
        assert_eq!(name("KEY_F13"), "F13");
        assert_eq!(name("KEY_LEFT"), "Left Arrow");
        assert_eq!(name("KEY_COMPOSE"), "Menu");
        assert_eq!(name("KEY_MUTE"), "Mute");
    }

    #[test]
    fn reads_capability_bitmaps_as_sysfs_prints_them() {
        let keys = Bitmap::parse(LAPTOP_KEYS, 64).unwrap();
        assert!(!keys.contains(0));
        assert!(keys.contains(usize::from(codes::KEY_ESC)));
        assert!(keys.contains(usize::from(codes::KEY_RIGHTCTRL)));
        assert!(keys.contains(30), "KEY_A");
        assert!(!keys.contains(1_000));
        let events = Bitmap::parse("120013", 64).unwrap();
        assert!(events.contains(EV_KEY));
        assert!(
            !Bitmap::parse("21", 64).unwrap().contains(EV_KEY),
            "a lid switch has no keys"
        );
        assert_eq!(Bitmap::parse("0", 64).unwrap().words, [0]);
        assert!(Bitmap::parse("xyz", 64).is_none());
    }

    #[test]
    fn reads_32_bit_words() {
        let keys = Bitmap::parse("1 80000000", 32).unwrap();
        assert!(keys.contains(31));
        assert!(keys.contains(32));
        assert!(!keys.contains(33));
    }

    #[test]
    fn names_keys_both_ways() {
        assert_eq!(key_code("KEY_RIGHTCTRL"), Some(codes::KEY_RIGHTCTRL));
        assert_eq!(key_code("rightctrl"), Some(codes::KEY_RIGHTCTRL));
        assert_eq!(key_code(" RightAlt "), Some(codes::KEY_RIGHTALT));
        assert_eq!(key_code("KEY_NOT_A_KEY"), None);
        assert_eq!(key_name(codes::KEY_RIGHTCTRL), "KEY_RIGHTCTRL");
        assert_eq!(key_name(0x110), "BTN_LEFT");
    }
}
