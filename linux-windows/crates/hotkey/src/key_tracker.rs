//! What each key event means for the dictation hotkey: the Mac app's HotkeyMatcher for a hotkey
//! that is one key on its own, with key codes from Linux's input events.
//!
//! - The hotkey's press and release are the gesture's. With several keyboards it counts as down
//!   while it is down on any of them, and a keyboard unplugged with it held releases it.
//! - Esc's press means escape.
//! - Any other key's press while the hotkey is held means another key: the user is typing a
//!   shortcut. Modifiers and locks don't count, as on the Mac, where they are flag changes rather
//!   than key presses; nor do mouse and gamepad buttons.
//! - The hotkey's own autorepeat means nothing, and neither does Esc's.
//! - While paused (Settings is recording a new shortcut), nothing means anything.
//!
//! Unlike the Mac app, nothing is swallowed: a program reading the keyboard can't hide a key
//! from the focused app without grabbing the whole keyboard, so the app sees the hotkey and Esc
//! too. Pick a key apps leave alone, such as Right Ctrl.

use std::collections::BTreeSet;

use crate::HotkeyInput;

/// Linux input event codes (linux/input-event-codes.h), which evdev reports.
pub mod codes {
    pub const KEY_ESC: u16 = 1;
    pub const KEY_LEFTCTRL: u16 = 29;
    pub const KEY_LEFTSHIFT: u16 = 42;
    pub const KEY_RIGHTSHIFT: u16 = 54;
    pub const KEY_LEFTALT: u16 = 56;
    pub const KEY_CAPSLOCK: u16 = 58;
    pub const KEY_NUMLOCK: u16 = 69;
    pub const KEY_SCROLLLOCK: u16 = 70;
    pub const KEY_RIGHTCTRL: u16 = 97;
    pub const KEY_RIGHTALT: u16 = 100;
    pub const KEY_LEFTMETA: u16 = 125;
    pub const KEY_RIGHTMETA: u16 = 126;
    pub const KEY_FN: u16 = 0x1d0;
}

/// A hotkey event for the dictation flow: the Mac app's HotkeyEvent, without undo.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HotkeyEvent {
    /// The dictation hotkey went down.
    Pressed,
    /// The dictation hotkey went up.
    Released,
    /// Esc was pressed.
    Escape,
    /// Another key was pressed while the hotkey was held.
    OtherKey,
}

impl HotkeyEvent {
    /// The gesture input for this event.
    pub fn gesture_input(self) -> HotkeyInput {
        match self {
            Self::Pressed => HotkeyInput::Pressed,
            Self::Released => HotkeyInput::Released,
            Self::Escape => HotkeyInput::Escape,
            Self::OtherKey => HotkeyInput::OtherKey,
        }
    }
}

/// What a key did, as the kernel reports it in a key event's value.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum KeyState {
    Released,
    Pressed,
    /// The key is still held and the keyboard repeats it.
    Repeated,
}

impl KeyState {
    /// The state for a key event's value: 0, 1 or 2. Anything else is not a key state.
    pub fn from_value(value: i32) -> Option<Self> {
        match value {
            0 => Some(Self::Released),
            1 => Some(Self::Pressed),
            2 => Some(Self::Repeated),
            _ => None,
        }
    }
}

/// Why a key can't be the dictation hotkey.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum UnusableHotkey {
    /// Esc already cancels dictation.
    Escape,
    /// A mouse, joystick or gamepad button, not a key.
    Button,
}

impl std::fmt::Display for UnusableHotkey {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(match self {
            Self::Escape => "Esc cancels dictation, so it can't also start it",
            Self::Button => "that is a mouse or gamepad button, not a key",
        })
    }
}

impl std::error::Error for UnusableHotkey {}

/// Turns key events from any number of keyboards into hotkey events. Pure: the keyboard
/// monitor feeds it, and it can be tested with plain values.
#[derive(Clone, Debug)]
pub struct KeyTracker {
    hotkey: u16,
    /// The keyboards the hotkey is down on.
    held_on: BTreeSet<u64>,
    paused: bool,
}

impl KeyTracker {
    /// A tracker for `hotkey`, an input event code (`codes::KEY_RIGHTCTRL`, say).
    pub fn new(hotkey: u16) -> Result<Self, UnusableHotkey> {
        check(hotkey)?;
        Ok(Self {
            hotkey,
            held_on: BTreeSet::new(),
            paused: false,
        })
    }

    pub fn hotkey(&self) -> u16 {
        self.hotkey
    }

    /// Watches for `hotkey` from now on. Whatever the old one was doing is forgotten without a
    /// word: whoever changes the hotkey deals with a dictation it started.
    pub fn set_hotkey(&mut self, hotkey: u16) -> Result<(), UnusableHotkey> {
        check(hotkey)?;
        self.hotkey = hotkey;
        self.held_on.clear();
        Ok(())
    }

    /// While paused, keys mean nothing, so that Settings can record a new shortcut. A hotkey
    /// held when the pause starts or ends is forgotten, as by [`Self::set_hotkey`]: its release
    /// means nothing either, and the next press is a press.
    pub fn set_paused(&mut self, paused: bool) {
        self.paused = paused;
        self.held_on.clear();
    }

    pub fn is_paused(&self) -> bool {
        self.paused
    }

    /// Whether the hotkey is down on any keyboard.
    pub fn is_held(&self) -> bool {
        !self.held_on.is_empty()
    }

    /// What `state` of key `code` on keyboard `device` means; `None` when nothing.
    pub fn key(&mut self, device: u64, code: u16, state: KeyState) -> Option<HotkeyEvent> {
        if self.paused {
            return None;
        }
        if code == self.hotkey {
            return match state {
                KeyState::Pressed => {
                    let was_held = self.is_held();
                    self.held_on.insert(device);
                    (!was_held).then_some(HotkeyEvent::Pressed)
                }
                KeyState::Released => {
                    let removed = self.held_on.remove(&device);
                    (removed && !self.is_held()).then_some(HotkeyEvent::Released)
                }
                KeyState::Repeated => None,
            };
        }
        if code == codes::KEY_ESC {
            // Repeats of an Esc already seen mean nothing more.
            return (state == KeyState::Pressed).then_some(HotkeyEvent::Escape);
        }
        // A key held since before the hotkey still counts when it repeats, as on the Mac: the
        // user is typing.
        let is_down = matches!(state, KeyState::Pressed | KeyState::Repeated);
        (is_down && self.is_held() && !is_modifier(code) && !is_button(code)).then_some(HotkeyEvent::OtherKey)
    }

    /// The keyboard `device` is gone: a hotkey held only there is released.
    pub fn device_removed(&mut self, device: u64) -> Option<HotkeyEvent> {
        let removed = self.held_on.remove(&device);
        (removed && !self.is_held()).then_some(HotkeyEvent::Released)
    }
}

/// Whether `hotkey` can be the dictation hotkey.
fn check(hotkey: u16) -> Result<(), UnusableHotkey> {
    if hotkey == codes::KEY_ESC {
        return Err(UnusableHotkey::Escape);
    }
    if is_button(hotkey) {
        return Err(UnusableHotkey::Button);
    }
    Ok(())
}

fn is_modifier(code: u16) -> bool {
    use codes::*;
    matches!(
        code,
        KEY_LEFTCTRL
            | KEY_RIGHTCTRL
            | KEY_LEFTSHIFT
            | KEY_RIGHTSHIFT
            | KEY_LEFTALT
            | KEY_RIGHTALT
            | KEY_LEFTMETA
            | KEY_RIGHTMETA
            | KEY_CAPSLOCK
            | KEY_NUMLOCK
            | KEY_SCROLLLOCK
            | KEY_FN
    )
}

/// Mouse, joystick, gamepad and trigger buttons, which share the key events' code space.
fn is_button(code: u16) -> bool {
    matches!(code, 0x100..=0x15f | 0x220..=0x223 | 0x2c0..=0x2e7)
}

#[cfg(test)]
mod tests {
    use super::HotkeyEvent::*;
    use super::KeyState::{Pressed as Down, Released as Up, Repeated as Repeat};
    use super::codes::*;
    use super::*;

    const KEY_A: u16 = 30;
    const BTN_LEFT: u16 = 0x110;
    const LAPTOP: u64 = 1;
    const USB: u64 = 2;

    fn tracker() -> KeyTracker {
        KeyTracker::new(KEY_RIGHTCTRL).unwrap()
    }

    #[test]
    fn the_hotkeys_press_and_release_are_reported() {
        let mut tracker = tracker();
        assert_eq!(tracker.key(LAPTOP, KEY_RIGHTCTRL, Down), Some(Pressed));
        assert!(tracker.is_held());
        assert_eq!(tracker.key(LAPTOP, KEY_RIGHTCTRL, Repeat), None);
        assert_eq!(tracker.key(LAPTOP, KEY_RIGHTCTRL, Up), Some(Released));
        assert!(!tracker.is_held());
    }

    #[test]
    fn a_release_without_a_press_is_ignored() {
        assert_eq!(tracker().key(LAPTOP, KEY_RIGHTCTRL, Up), None);
    }

    #[test]
    fn the_hotkey_is_down_while_it_is_down_on_any_keyboard() {
        let mut tracker = tracker();
        assert_eq!(tracker.key(LAPTOP, KEY_RIGHTCTRL, Down), Some(Pressed));
        assert_eq!(tracker.key(USB, KEY_RIGHTCTRL, Down), None);
        assert_eq!(tracker.key(LAPTOP, KEY_RIGHTCTRL, Up), None);
        assert_eq!(tracker.key(USB, KEY_RIGHTCTRL, Up), Some(Released));
    }

    #[test]
    fn unplugging_the_keyboard_that_holds_the_hotkey_releases_it() {
        let mut tracker = tracker();
        tracker.key(USB, KEY_RIGHTCTRL, Down);
        assert_eq!(tracker.device_removed(LAPTOP), None);
        assert_eq!(tracker.device_removed(USB), Some(Released));
        assert_eq!(tracker.device_removed(USB), None);
    }

    #[test]
    fn escape_is_reported_once_per_press_whether_or_not_the_hotkey_is_held() {
        let mut tracker = tracker();
        assert_eq!(tracker.key(LAPTOP, KEY_ESC, Down), Some(Escape));
        assert_eq!(tracker.key(LAPTOP, KEY_ESC, Repeat), None);
        assert_eq!(tracker.key(LAPTOP, KEY_ESC, Up), None);
        tracker.key(LAPTOP, KEY_RIGHTCTRL, Down);
        assert_eq!(tracker.key(LAPTOP, KEY_ESC, Down), Some(Escape));
    }

    #[test]
    fn another_key_counts_only_while_the_hotkey_is_held() {
        let mut tracker = tracker();
        assert_eq!(tracker.key(LAPTOP, KEY_A, Down), None);
        tracker.key(LAPTOP, KEY_RIGHTCTRL, Down);
        assert_eq!(tracker.key(USB, KEY_A, Down), Some(OtherKey));
        assert_eq!(tracker.key(USB, KEY_A, Repeat), Some(OtherKey));
        assert_eq!(tracker.key(USB, KEY_A, Up), None);
    }

    #[test]
    fn modifiers_locks_and_buttons_are_not_other_keys() {
        let mut tracker = tracker();
        tracker.key(LAPTOP, KEY_RIGHTCTRL, Down);
        for code in [
            KEY_LEFTSHIFT,
            KEY_LEFTCTRL,
            KEY_LEFTALT,
            KEY_RIGHTALT,
            KEY_LEFTMETA,
            KEY_CAPSLOCK,
            KEY_FN,
            BTN_LEFT,
        ] {
            assert_eq!(tracker.key(LAPTOP, code, Down), None, "code {code}");
        }
        assert!(tracker.is_held());
    }

    #[test]
    fn a_letter_can_be_the_hotkey() {
        let mut tracker = KeyTracker::new(KEY_A).unwrap();
        assert_eq!(tracker.key(LAPTOP, KEY_A, Down), Some(Pressed));
        assert_eq!(tracker.key(LAPTOP, KEY_RIGHTCTRL, Down), None);
        assert_eq!(tracker.key(LAPTOP, 31, Down), Some(OtherKey));
    }

    #[test]
    fn escape_and_buttons_cant_be_the_hotkey() {
        assert_eq!(KeyTracker::new(KEY_ESC).unwrap_err(), UnusableHotkey::Escape);
        assert_eq!(KeyTracker::new(BTN_LEFT).unwrap_err(), UnusableHotkey::Button);
    }

    #[test]
    fn a_new_hotkey_replaces_the_old_one_and_forgets_it_was_held() {
        let mut tracker = tracker();
        tracker.key(LAPTOP, KEY_RIGHTCTRL, Down);
        tracker.set_hotkey(KEY_RIGHTALT).unwrap();
        assert_eq!(tracker.hotkey(), KEY_RIGHTALT);
        assert!(!tracker.is_held());
        assert_eq!(tracker.key(LAPTOP, KEY_RIGHTCTRL, Up), None, "the old hotkey's release");
        assert_eq!(
            tracker.key(LAPTOP, KEY_RIGHTCTRL, Down),
            None,
            "the old hotkey is an ordinary key"
        );
        assert_eq!(tracker.key(LAPTOP, KEY_RIGHTALT, Down), Some(Pressed));
        assert_eq!(tracker.key(LAPTOP, KEY_RIGHTALT, Up), Some(Released));
    }

    #[test]
    fn an_unusable_hotkey_leaves_the_old_one_in_place() {
        let mut tracker = tracker();
        tracker.key(LAPTOP, KEY_RIGHTCTRL, Down);
        assert_eq!(tracker.set_hotkey(KEY_ESC), Err(UnusableHotkey::Escape));
        assert_eq!(tracker.set_hotkey(BTN_LEFT), Err(UnusableHotkey::Button));
        assert_eq!(tracker.hotkey(), KEY_RIGHTCTRL);
        assert_eq!(tracker.key(LAPTOP, KEY_RIGHTCTRL, Up), Some(Released), "still held");
    }

    #[test]
    fn nothing_means_anything_while_paused() {
        let mut tracker = tracker();
        tracker.key(LAPTOP, KEY_RIGHTCTRL, Down);
        tracker.set_paused(true);
        assert!(tracker.is_paused());
        for (code, state) in [
            (KEY_RIGHTCTRL, Up),
            (KEY_RIGHTCTRL, Down),
            (KEY_A, Down),
            (KEY_ESC, Down),
        ] {
            assert_eq!(tracker.key(LAPTOP, code, state), None, "code {code}");
        }
        assert_eq!(tracker.device_removed(LAPTOP), None);
        // Held through the end of the pause: its release means nothing, and the next press counts.
        tracker.set_paused(false);
        assert_eq!(tracker.key(LAPTOP, KEY_RIGHTCTRL, Up), None);
        assert_eq!(tracker.key(LAPTOP, KEY_RIGHTCTRL, Down), Some(Pressed));
    }

    #[test]
    fn key_states_come_from_event_values() {
        assert_eq!(KeyState::from_value(0), Some(Up));
        assert_eq!(KeyState::from_value(1), Some(Down));
        assert_eq!(KeyState::from_value(2), Some(Repeat));
        assert_eq!(KeyState::from_value(3), None);
    }

    #[test]
    fn events_map_to_gesture_inputs() {
        assert_eq!(Pressed.gesture_input(), HotkeyInput::Pressed);
        assert_eq!(Released.gesture_input(), HotkeyInput::Released);
        assert_eq!(Escape.gesture_input(), HotkeyInput::Escape);
        assert_eq!(OtherKey.gesture_input(), HotkeyInput::OtherKey);
    }
}
