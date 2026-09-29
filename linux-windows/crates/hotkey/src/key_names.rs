//! Keys by name. The settings keep the hotkey as linux/input-event-codes.h names its key
//! (`KEY_RIGHTCTRL`) on every system, and the Settings window records it by the key's place on the
//! keyboard (KeyboardEvent.code), which is what those codes number too. Linux names every key
//! through evdev; elsewhere this table does, for the keys the Settings window can record and
//! `livetranscribe keys` can print. It also gives each key the virtual-key code Windows' keyboard
//! hook reports for it, where one does: a key Windows reports as another's, such as the keypad's
//! Enter (Enter's, with a flag the hook's events don't carry here), can't be the hotkey there.
//! Letters and punctuation follow the keyboard layout on Windows, as virtual-key codes do.
//!
//! [`display_name`] says a key's name as people do, everywhere.

#[cfg(not(target_os = "linux"))]
use crate::key_tracker::codes;

/// A key the table knows.
#[cfg_attr(target_os = "linux", allow(dead_code, reason = "Linux names keys through evdev"))]
struct Key {
    /// Its Linux input event code.
    code: u16,
    /// Its name in linux/input-event-codes.h.
    name: &'static str,
    /// The virtual-key code Windows' keyboard hook reports for it, if one does.
    virtual_key: Option<u16>,
}

const fn key(code: u16, name: &'static str, virtual_key: u16) -> Key {
    Key {
        code,
        name,
        virtual_key: Some(virtual_key),
    }
}

const fn unwatched(code: u16, name: &'static str) -> Key {
    Key {
        code,
        name,
        virtual_key: None,
    }
}

/// Every key the table knows, in code order. A virtual-key code two keys share (the ISO key and
/// the Japanese ろ, Korean Hangul and Japanese kana, backslash and yen) is on different keyboards.
#[cfg_attr(target_os = "linux", allow(dead_code, reason = "Linux names keys through evdev"))]
const KEYS: &[Key] = &[
    key(1, "KEY_ESC", 0x1B),
    key(2, "KEY_1", 0x31),
    key(3, "KEY_2", 0x32),
    key(4, "KEY_3", 0x33),
    key(5, "KEY_4", 0x34),
    key(6, "KEY_5", 0x35),
    key(7, "KEY_6", 0x36),
    key(8, "KEY_7", 0x37),
    key(9, "KEY_8", 0x38),
    key(10, "KEY_9", 0x39),
    key(11, "KEY_0", 0x30),
    key(12, "KEY_MINUS", 0xBD),
    key(13, "KEY_EQUAL", 0xBB),
    key(14, "KEY_BACKSPACE", 0x08),
    key(15, "KEY_TAB", 0x09),
    key(16, "KEY_Q", 0x51),
    key(17, "KEY_W", 0x57),
    key(18, "KEY_E", 0x45),
    key(19, "KEY_R", 0x52),
    key(20, "KEY_T", 0x54),
    key(21, "KEY_Y", 0x59),
    key(22, "KEY_U", 0x55),
    key(23, "KEY_I", 0x49),
    key(24, "KEY_O", 0x4F),
    key(25, "KEY_P", 0x50),
    key(26, "KEY_LEFTBRACE", 0xDB),
    key(27, "KEY_RIGHTBRACE", 0xDD),
    key(28, "KEY_ENTER", 0x0D),
    key(29, "KEY_LEFTCTRL", 0xA2),
    key(30, "KEY_A", 0x41),
    key(31, "KEY_S", 0x53),
    key(32, "KEY_D", 0x44),
    key(33, "KEY_F", 0x46),
    key(34, "KEY_G", 0x47),
    key(35, "KEY_H", 0x48),
    key(36, "KEY_J", 0x4A),
    key(37, "KEY_K", 0x4B),
    key(38, "KEY_L", 0x4C),
    key(39, "KEY_SEMICOLON", 0xBA),
    key(40, "KEY_APOSTROPHE", 0xDE),
    key(41, "KEY_GRAVE", 0xC0),
    key(42, "KEY_LEFTSHIFT", 0xA0),
    key(43, "KEY_BACKSLASH", 0xDC),
    key(44, "KEY_Z", 0x5A),
    key(45, "KEY_X", 0x58),
    key(46, "KEY_C", 0x43),
    key(47, "KEY_V", 0x56),
    key(48, "KEY_B", 0x42),
    key(49, "KEY_N", 0x4E),
    key(50, "KEY_M", 0x4D),
    key(51, "KEY_COMMA", 0xBC),
    key(52, "KEY_DOT", 0xBE),
    key(53, "KEY_SLASH", 0xBF),
    key(54, "KEY_RIGHTSHIFT", 0xA1),
    key(55, "KEY_KPASTERISK", 0x6A),
    key(56, "KEY_LEFTALT", 0xA4),
    key(57, "KEY_SPACE", 0x20),
    key(58, "KEY_CAPSLOCK", 0x14),
    key(59, "KEY_F1", 0x70),
    key(60, "KEY_F2", 0x71),
    key(61, "KEY_F3", 0x72),
    key(62, "KEY_F4", 0x73),
    key(63, "KEY_F5", 0x74),
    key(64, "KEY_F6", 0x75),
    key(65, "KEY_F7", 0x76),
    key(66, "KEY_F8", 0x77),
    key(67, "KEY_F9", 0x78),
    key(68, "KEY_F10", 0x79),
    key(69, "KEY_NUMLOCK", 0x90),
    key(70, "KEY_SCROLLLOCK", 0x91),
    key(71, "KEY_KP7", 0x67),
    key(72, "KEY_KP8", 0x68),
    key(73, "KEY_KP9", 0x69),
    key(74, "KEY_KPMINUS", 0x6D),
    key(75, "KEY_KP4", 0x64),
    key(76, "KEY_KP5", 0x65),
    key(77, "KEY_KP6", 0x66),
    key(78, "KEY_KPPLUS", 0x6B),
    key(79, "KEY_KP1", 0x61),
    key(80, "KEY_KP2", 0x62),
    key(81, "KEY_KP3", 0x63),
    key(82, "KEY_KP0", 0x60),
    key(83, "KEY_KPDOT", 0x6E),
    key(86, "KEY_102ND", 0xE2),
    key(87, "KEY_F11", 0x7A),
    key(88, "KEY_F12", 0x7B),
    key(89, "KEY_RO", 0xE2),
    key(92, "KEY_HENKAN", 0x1C),
    key(93, "KEY_KATAKANAHIRAGANA", 0x15),
    key(94, "KEY_MUHENKAN", 0x1D),
    unwatched(96, "KEY_KPENTER"),
    key(97, "KEY_RIGHTCTRL", 0xA3),
    key(98, "KEY_KPSLASH", 0x6F),
    key(99, "KEY_SYSRQ", 0x2C),
    key(100, "KEY_RIGHTALT", 0xA5),
    key(102, "KEY_HOME", 0x24),
    key(103, "KEY_UP", 0x26),
    key(104, "KEY_PAGEUP", 0x21),
    key(105, "KEY_LEFT", 0x25),
    key(106, "KEY_RIGHT", 0x27),
    key(107, "KEY_END", 0x23),
    key(108, "KEY_DOWN", 0x28),
    key(109, "KEY_PAGEDOWN", 0x22),
    key(110, "KEY_INSERT", 0x2D),
    key(111, "KEY_DELETE", 0x2E),
    key(113, "KEY_MUTE", 0xAD),
    key(114, "KEY_VOLUMEDOWN", 0xAE),
    key(115, "KEY_VOLUMEUP", 0xAF),
    unwatched(117, "KEY_KPEQUAL"),
    key(119, "KEY_PAUSE", 0x13),
    unwatched(121, "KEY_KPCOMMA"),
    key(122, "KEY_HANGEUL", 0x15),
    key(123, "KEY_HANJA", 0x19),
    key(124, "KEY_YEN", 0xDC),
    key(125, "KEY_LEFTMETA", 0x5B),
    key(126, "KEY_RIGHTMETA", 0x5C),
    key(127, "KEY_COMPOSE", 0x5D),
    key(138, "KEY_HELP", 0x2F),
    key(163, "KEY_NEXTSONG", 0xB0),
    key(164, "KEY_PLAYPAUSE", 0xB3),
    key(165, "KEY_PREVIOUSSONG", 0xB1),
    key(166, "KEY_STOPCD", 0xB2),
    key(183, "KEY_F13", 0x7C),
    key(184, "KEY_F14", 0x7D),
    key(185, "KEY_F15", 0x7E),
    key(186, "KEY_F16", 0x7F),
    key(187, "KEY_F17", 0x80),
    key(188, "KEY_F18", 0x81),
    key(189, "KEY_F19", 0x82),
    key(190, "KEY_F20", 0x83),
    key(191, "KEY_F21", 0x84),
    key(192, "KEY_F22", 0x85),
    key(193, "KEY_F23", 0x86),
    key(194, "KEY_F24", 0x87),
    // What the Windows hook reports a key the table doesn't know as.
    unwatched(240, "KEY_UNKNOWN"),
];

#[cfg_attr(target_os = "linux", allow(dead_code, reason = "Linux names keys through evdev"))]
fn by_code(code: u16) -> Option<&'static Key> {
    KEYS.iter().find(|key| key.code == code)
}

/// The input event code for a key name as linux/input-event-codes.h spells it, with or without
/// `KEY_` and in any case: `KEY_RIGHTCTRL`, `rightctrl`, `RightCtrl`.
#[cfg(not(target_os = "linux"))]
pub fn key_code(name: &str) -> Option<u16> {
    let upper = name.trim().to_ascii_uppercase();
    let full = if upper.starts_with("KEY_") {
        upper
    } else {
        format!("KEY_{upper}")
    };
    KEYS.iter().find(|key| key.name == full).map(|key| key.code)
}

/// The name of an input event code, such as `KEY_RIGHTCTRL`.
#[cfg(not(target_os = "linux"))]
pub fn key_name(code: u16) -> String {
    by_code(code).map_or_else(|| format!("key {code}"), |key| key.name.to_owned())
}

/// The virtual-key code Windows reports for the key `code`, if it reports one of its own.
#[cfg_attr(not(windows), allow(dead_code, reason = "the Windows keyboard monitor's"))]
pub(crate) fn virtual_key(code: u16) -> Option<u16> {
    by_code(code).and_then(|key| key.virtual_key)
}

/// The input event code for a key Windows reports as `virtual_key`: the hotkey's, when the hotkey
/// is a key with that code, since a code two keys share is on different keyboards; otherwise the
/// first key with it, and `KEY_UNKNOWN` for a key the table doesn't know, which is still a key.
#[cfg(not(target_os = "linux"))]
#[cfg_attr(not(windows), allow(dead_code, reason = "the Windows keyboard monitor's"))]
pub(crate) fn code_for_virtual_key(virtual_key: u16, hotkey: Option<u16>) -> u16 {
    if let Some(hotkey) = hotkey
        && self::virtual_key(hotkey) == Some(virtual_key)
    {
        return hotkey;
    }
    KEYS.iter()
        .find(|key| key.virtual_key == Some(virtual_key))
        .map_or(codes::KEY_UNKNOWN, |key| key.code)
}

/// A key's name as people say it, for the panel and the menu: `KEY_RIGHTCTRL` is "Right Ctrl".
pub fn display_name(code: u16) -> String {
    let name = crate::key_name(code);
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
        // The key with the Windows logo, as Windows calls it.
        "META" if cfg!(windows) => "Windows".to_owned(),
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::key_tracker::codes;

    #[test]
    fn keys_are_named_as_people_say_them() {
        let name = |key: &str| display_name(crate::key_code(key).expect("a key"));
        assert_eq!(name("KEY_RIGHTCTRL"), "Right Ctrl");
        assert_eq!(name("KEY_LEFTALT"), "Left Alt");
        let right_meta = if cfg!(windows) { "Right Windows" } else { "Right Super" };
        assert_eq!(name("KEY_RIGHTMETA"), right_meta);
        assert_eq!(name("KEY_CAPSLOCK"), "Caps Lock");
        assert_eq!(name("KEY_F13"), "F13");
        assert_eq!(name("KEY_LEFT"), "Left Arrow");
        assert_eq!(name("KEY_COMPOSE"), "Menu");
        assert_eq!(name("KEY_MUTE"), "Mute");
    }

    #[test]
    fn the_table_is_in_code_order_with_one_name_per_code() {
        for pair in KEYS.windows(2) {
            assert!(pair[0].code < pair[1].code, "{} before {}", pair[0].name, pair[1].name);
        }
        let mut names: Vec<_> = KEYS.iter().map(|key| key.name).collect();
        names.sort_unstable();
        names.dedup();
        assert_eq!(names.len(), KEYS.len(), "a name twice");
    }

    #[test]
    fn a_virtual_key_code_two_keys_share_is_on_different_keyboards() {
        let mut shared: Vec<Vec<&str>> = Vec::new();
        for key in KEYS {
            let others: Vec<&str> = KEYS
                .iter()
                .filter(|other| other.virtual_key.is_some() && other.virtual_key == key.virtual_key)
                .map(|other| other.name)
                .collect();
            if others.len() > 1 && !shared.contains(&others) {
                shared.push(others);
            }
        }
        shared.sort();
        assert_eq!(
            shared,
            [
                vec!["KEY_102ND", "KEY_RO"],
                vec!["KEY_BACKSLASH", "KEY_YEN"],
                vec!["KEY_KATAKANAHIRAGANA", "KEY_HANGEUL"],
            ]
        );
    }

    #[test]
    fn the_modifiers_and_escape_have_virtual_keys_of_their_own() {
        assert_eq!(virtual_key(codes::KEY_ESC), Some(0x1B));
        assert_eq!(virtual_key(codes::KEY_RIGHTCTRL), Some(0xA3));
        assert_eq!(virtual_key(codes::KEY_LEFTCTRL), Some(0xA2));
        assert_eq!(virtual_key(codes::KEY_RIGHTALT), Some(0xA5));
        assert_eq!(virtual_key(codes::KEY_RIGHTSHIFT), Some(0xA1));
        assert_eq!(virtual_key(codes::KEY_RIGHTMETA), Some(0x5C));
        assert_eq!(virtual_key(96), None, "the keypad's Enter is Enter to Windows");
        assert_eq!(virtual_key(codes::KEY_FN), None, "Fn never reaches Windows");
    }

    #[cfg(not(target_os = "linux"))]
    #[test]
    fn names_keys_both_ways() {
        assert_eq!(key_code("KEY_RIGHTCTRL"), Some(codes::KEY_RIGHTCTRL));
        assert_eq!(key_code("rightctrl"), Some(codes::KEY_RIGHTCTRL));
        assert_eq!(key_code(" RightAlt "), Some(codes::KEY_RIGHTALT));
        assert_eq!(key_code("KEY_NOT_A_KEY"), None);
        assert_eq!(key_name(codes::KEY_RIGHTCTRL), "KEY_RIGHTCTRL");
        assert_eq!(key_name(0x110), "key 272");
    }

    #[cfg(not(target_os = "linux"))]
    #[test]
    fn a_virtual_key_is_the_hotkeys_when_the_hotkey_shares_it() {
        const KEY_102ND: u16 = 86;
        const KEY_RO: u16 = 89;
        assert_eq!(code_for_virtual_key(0xE2, None), KEY_102ND);
        assert_eq!(code_for_virtual_key(0xE2, Some(KEY_RO)), KEY_RO);
        assert_eq!(code_for_virtual_key(0xE2, Some(codes::KEY_RIGHTCTRL)), KEY_102ND);
        assert_eq!(
            code_for_virtual_key(0xA3, Some(codes::KEY_RIGHTCTRL)),
            codes::KEY_RIGHTCTRL
        );
        assert_eq!(code_for_virtual_key(0x0D, None), 28, "Enter");
        assert_eq!(
            code_for_virtual_key(0xE7, None),
            codes::KEY_UNKNOWN,
            "a key the table doesn't know"
        );
    }

    /// The table names each key as evdev does, which names them on Linux.
    #[cfg(target_os = "linux")]
    #[test]
    fn the_table_names_keys_as_evdev_does() {
        for key in KEYS {
            assert_eq!(crate::key_name(key.code), key.name);
            assert_eq!(crate::key_code(key.name), Some(key.code), "{}", key.name);
        }
    }
}
