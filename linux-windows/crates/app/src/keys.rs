//! `livetranscribe keys`: prints the name of each key pressed, to choose `run --key`. It stops
//! by itself after a while, since it shows everything typed meanwhile.

use std::thread;
use std::time::Duration;

use lt_hotkey::{KeyState, KeyboardEvent, key_name, watch_keyboards};

use crate::dictation::hotkey_problem;

const LISTEN_FOR: Duration = Duration::from_secs(30);
/// Every key code; mouse and gamepad buttons come after.
const KEY_CODES: std::ops::Range<u16> = 1..0x100;

pub fn run() -> anyhow::Result<()> {
    let watching = watch_keyboards(KEY_CODES.collect(), |event| {
        if let KeyboardEvent::Key {
            keyboard,
            code,
            state: KeyState::Pressed,
        } = event
        {
            println!("{} ({code}) on {}", key_name(code), keyboard.name);
        }
    });
    let keyboards = watching.map_err(|error| anyhow::anyhow!(hotkey_problem(&error)))?;
    let names: Vec<_> = keyboards.iter().map(|keyboard| keyboard.name.as_str()).collect();
    eprintln!(
        "Press the key you want to hold for dictation; its name is what `run --key` takes. \
         Listening to {} for {} s.",
        if names.is_empty() {
            "keyboards as they are plugged in".to_owned()
        } else {
            names.join(", ")
        },
        LISTEN_FOR.as_secs()
    );
    thread::sleep(LISTEN_FOR);
    Ok(())
}
