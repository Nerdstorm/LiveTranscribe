//! The dictation hotkey, mirroring the Mac app's `Hotkey` module
//! (Packages/LiveTranscribeKit/Sources/Hotkey): the hold, tap and double-tap gesture as a pure
//! state machine, what each key event means for it, and, on Linux, watching the keyboards.

mod hotkey_gesture;
mod key_tracker;
#[cfg(target_os = "linux")]
mod keyboard_monitor;

pub use hotkey_gesture::{HotkeyAction, HotkeyGesture, HotkeyGestureConfiguration, HotkeyInput};
pub use key_tracker::{HotkeyEvent, KeyState, KeyTracker, UnusableHotkey, codes};
#[cfg(target_os = "linux")]
pub use keyboard_monitor::{
    Keyboard, KeyboardEvent, MonitorError, display_name, key_code, key_name, watch_hotkey, watch_keyboards,
};
