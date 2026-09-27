//! `livetranscribe run`: dictation, as the Mac app's menu bar app has it. Hold the hotkey and
//! speak; on release the speech is transcribed, the text rules applied, and the text typed into
//! the focused field. A double tap records hands-free until the next press; Esc cancels. While
//! you dictate, a small circle by the mouse pointer shows the microphone's level, and the tray's
//! menu starts, stops and cancels dictation, copies the last one and sets the cleanup level.
//!
//! The flow is lt_dictation's DictationController, as on the Mac, on a thread of its own
//! ([`engine`]); the tray (Tauri) has the main thread. What was said is never printed or logged:
//! only counts.

mod engine;
mod platform;
mod single_instance;
mod transcriber;
mod tray;

use std::sync::mpsc;
use std::time::Duration;

use anyhow::Context;
use lt_capture::{Recorder, RecorderConfiguration};
use lt_dictation::{Configuration, ControllerConfiguration};
use lt_dictation_ui::{PanelView, load_interface_font};
use lt_hotkey::{HotkeyGestureConfiguration, display_name, key_code, key_name, watch_hotkey};
use lt_insertion::InsertionConfiguration;
use lt_shared::CleanupLevel;
use lt_wayland::{PanelConfiguration, SessionConfiguration, WaylandSession};

use crate::ModelOptions;
use engine::{Engine, Message};

/// The Mac app's defaults (DictationSettings.defaults).
const TAP_MAX_MS: u64 = 300;
const DOUBLE_TAP_WINDOW_MS: u64 = 300;
const MIN_UTTERANCE_MS: usize = 300;
const MAX_RECORDING_SECONDS: u32 = 300;
/// How long each of the panel's messages shows.
const NOTICE_MS: u64 = 2_500;
const PASTE_RESTORE_DELAY: Duration = Duration::from_millis(250);
/// How long an app gets to read pasted text before it is left on the clipboard instead.
const PASTE_READ_TIMEOUT: Duration = Duration::from_secs(2);

#[derive(clap::Args)]
pub struct Options {
    #[command(flatten)]
    model: ModelOptions,
    /// The key to hold, as linux/input-event-codes.h names it (`livetranscribe keys` shows the
    /// name of each key you press)
    #[arg(long, default_value = "KEY_RIGHTCTRL", value_name = "KEY")]
    key: String,
    /// Don't turn a double tap into hands-free recording
    #[arg(long)]
    no_hands_free: bool,
    /// How much the text rules may change what was said; the tray's menu changes it too
    #[arg(long, default_value = "medium", value_parser = parse_cleanup)]
    cleanup: CleanupLevel,
}

fn parse_cleanup(name: &str) -> Result<CleanupLevel, String> {
    CleanupLevel::ALL
        .into_iter()
        .find(|level| level.as_str() == name)
        .ok_or_else(|| "one of none, light, medium or high".to_owned())
}

pub fn run(options: &Options) -> anyhow::Result<()> {
    let hotkey = key_code(&options.key).with_context(|| {
        format!(
            "{} isn't a key name; `livetranscribe keys` shows the names",
            options.key
        )
    })?;
    let _instance = single_instance::acquire()?;

    // The quick checks first, so a missing permission shows before the model loads.
    let recorder = Recorder::new(RecorderConfiguration {
        max_duration_seconds: MAX_RECORDING_SECONDS,
    })
    .context("couldn't start the recorder")?;
    let level = recorder.level();
    let panel = match load_interface_font() {
        Ok(typeface) => Some(PanelConfiguration {
            view: PanelView::new(typeface),
            level: Box::new(move || level.get()),
        }),
        Err(error) => {
            eprintln!("⚠ Dictation will run without its panel: {error}");
            None
        }
    };
    let (messages, received) = mpsc::channel();
    let session = WaylandSession::connect(SessionConfiguration {
        insertion: InsertionConfiguration {
            restore_delay: PASTE_RESTORE_DELAY,
            read_timeout: PASTE_READ_TIMEOUT,
        },
        panel,
    })?;
    let hotkey_messages = messages.clone();
    let keyboards = watch_hotkey(hotkey, move |event| {
        let _ = hotkey_messages.send(Message::Hotkey(event));
    })?;
    for keyboard in &keyboards {
        eprintln!("Listening for {} on {}", key_name(hotkey), keyboard.name);
    }

    let hands_free = !options.no_hands_free;
    let engine = Engine {
        configuration: ControllerConfiguration {
            gesture: HotkeyGestureConfiguration {
                tap_max_ms: TAP_MAX_MS,
                double_tap_window_ms: DOUBLE_TAP_WINDOW_MS,
                hands_free_enabled: hands_free,
            },
            min_utterance_ms: MIN_UTTERANCE_MS,
            max_recording_seconds: MAX_RECORDING_SECONDS,
            text: Configuration {
                level: options.cleanup,
                snippets: Vec::new(),
                vocabulary: Vec::new(),
                // Each field says whether it takes line breaks.
                multiline: false,
            },
        },
        model: options.model.clone(),
        hotkey: display_name(hotkey),
        notice_ms: NOTICE_MS,
        recorder,
        session,
        messages: messages.clone(),
        received,
    };
    tray::run(messages, options.cleanup, move |status| engine.start(status))
}
