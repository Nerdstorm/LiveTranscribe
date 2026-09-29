//! The dictation hotkey, mirroring the Mac app's `Hotkey` module
//! (Packages/LiveTranscribeKit/Sources/Hotkey): the hold, tap and double-tap gesture as a pure
//! state machine, what each key event means for it, keys by name, and watching the keyboards: with
//! evdev on Linux, and a low-level keyboard hook on Windows.

mod hotkey_gesture;
mod key_names;
mod key_tracker;
#[cfg(target_os = "linux")]
mod keyboard_monitor;
#[cfg(windows)]
mod windows_monitor;

pub use hotkey_gesture::{HotkeyAction, HotkeyGesture, HotkeyGestureConfiguration, HotkeyInput};
pub use key_names::display_name;
#[cfg(not(target_os = "linux"))]
pub use key_names::{key_code, key_name};
pub use key_tracker::{HotkeyEvent, KeyState, KeyTracker, UnusableHotkey, codes};
#[cfg(target_os = "linux")]
pub use keyboard_monitor::{
    HotkeyWatch, Keyboard, KeyboardEvent, MonitorError, key_code, key_name, watch_hotkey, watch_keyboards,
};
#[cfg(windows)]
pub use windows_monitor::{HotkeyWatch, Keyboard, KeyboardEvent, MonitorError, watch_hotkey, watch_keyboards};
