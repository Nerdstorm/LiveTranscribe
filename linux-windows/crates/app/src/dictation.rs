//! `livetranscribe run`: dictation, as the Mac app's menu bar app has it. Hold the hotkey and
//! speak; on release the speech is transcribed, the text rules applied, and the text typed into
//! the focused field. A double tap records hands-free until the next press; Esc cancels. While
//! you dictate, a small circle by the mouse pointer shows the microphone's level, and the tray's
//! menu starts, stops and cancels dictation, copies the last one, sets the cleanup level and
//! opens Settings, whose changes apply without a restart.
//!
//! The flow is lt_dictation's DictationController, as on the Mac, on a thread of its own
//! ([`engine`]); the tray (Tauri) has the main thread. What was said is never printed or logged:
//! only counts.

mod configuration;
mod engine;
mod platform;
mod single_instance;
mod transcriber;
mod tray;

use std::path::PathBuf;
use std::sync::Arc;
use std::sync::mpsc::{self, Sender};

use anyhow::Context;
use lt_capture::Recorder;
use lt_dictation_ui::{PanelView, load_interface_font};
use lt_hotkey::{key_code, key_name, watch_hotkey};
use lt_shared::CleanupLevel;
use lt_wayland::{PanelConfiguration, SessionConfiguration, WaylandSession};
use serde_json::{Map, Value};

use crate::paths;
use crate::settings::{AppControl, SettingsService, SettingsStore};
use engine::{Engine, Message};

/// Settings for this run only, over the ones Settings keeps (the tray's *Settings…*), which
/// they leave as they are. Changing one in the app ends its override.
#[derive(clap::Args)]
pub struct Options {
    /// The speech model's folder, as tools/export-qwen3-asr.py wrote it [default: Settings'
    /// model, which at first is the app's data folder's models/qwen3-asr-0.6b-sinhala]
    #[arg(long, value_name = "FOLDER")]
    model: Option<PathBuf>,
    /// Where the model runs: auto (the NPU if there is one, and the CPU for what the NPU can't
    /// run), or only on one OpenVINO device: CPU, GPU or NPU [default: Settings']
    #[arg(long, value_name = "DEVICE")]
    device: Option<String>,
    /// The key to hold, as linux/input-event-codes.h names it (`livetranscribe keys` shows the
    /// name of each key you press) [default: Settings', at first KEY_RIGHTCTRL]
    #[arg(long, value_name = "KEY")]
    key: Option<String>,
    /// Don't turn a double tap into hands-free recording
    #[arg(long)]
    no_hands_free: bool,
    /// How much the text rules may change what was said: none, light, medium or high [default:
    /// Settings', at first medium]
    #[arg(long, value_parser = parse_cleanup)]
    cleanup: Option<CleanupLevel>,
}

impl Options {
    /// The options given, as settings.
    fn overrides(&self) -> anyhow::Result<Map<String, Value>> {
        let mut overrides = Map::new();
        if let Some(model) = &self.model {
            let absolute = std::path::absolute(model).with_context(|| format!("{} isn't a path", model.display()))?;
            let absolute = absolute
                .to_str()
                .with_context(|| format!("{} isn't UTF-8", absolute.display()))?;
            overrides.insert("sttModel".to_owned(), Value::from(absolute));
        }
        if let Some(device) = &self.device {
            overrides.insert("sttDevice".to_owned(), Value::from(device.as_str()));
        }
        if let Some(key) = &self.key {
            overrides.insert("dictationHotkey".to_owned(), Value::from(key.as_str()));
        }
        if self.no_hands_free {
            overrides.insert("handsFreeEnabled".to_owned(), Value::from(false));
        }
        if let Some(cleanup) = self.cleanup {
            overrides.insert("cleanupLevel".to_owned(), Value::from(cleanup.as_str()));
        }
        Ok(overrides)
    }
}

fn parse_cleanup(name: &str) -> Result<CleanupLevel, String> {
    CleanupLevel::ALL
        .into_iter()
        .find(|level| level.as_str() == name)
        .ok_or_else(|| "one of none, light, medium or high".to_owned())
}

pub fn run(options: &Options) -> anyhow::Result<()> {
    let overrides = options.overrides()?;
    let _instance = single_instance::acquire()?;
    let (store, problems) = SettingsStore::open(paths::settings_file()?, overrides);
    for problem in &problems {
        eprintln!("⚠ Settings: {problem}");
    }
    let settings = Arc::new(SettingsService::new(store));
    let current = settings.current().0;
    // The settings only hold keys that can be the hotkey.
    let hotkey = key_code(&current.dictation_hotkey)
        .with_context(|| format!("{} isn't a key name", current.dictation_hotkey))?;

    // The quick checks first, so a missing permission shows before the model loads.
    let recorder = Recorder::new(configuration::recorder(&current)).context("couldn't start the recorder")?;
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
        insertion: configuration::insertion(&current),
        panel,
    })?;
    let hotkey_messages = messages.clone();
    let (hotkey_watch, keyboards) = watch_hotkey(hotkey, move |event| {
        let _ = hotkey_messages.send(Message::Hotkey(event));
    })?;
    for keyboard in &keyboards {
        eprintln!("Listening for {} on {}", key_name(hotkey), keyboard.name);
    }

    // Each saved change reaches the engine, which applies it from the next dictation.
    let changes = messages.clone();
    settings.subscribe(move |settings, _| {
        let _ = changes.send(Message::Settings(Box::new(settings.clone())));
    });
    let engine = Engine {
        settings: current,
        hotkey: hotkey_watch,
        recorder,
        session,
        messages: messages.clone(),
        received,
    };
    let control = Box::new(EngineControl(messages.clone()));
    tray::run(messages, settings, control, move |status| engine.start(status))
}

/// The Settings window's way to the engine.
struct EngineControl(Sender<Message>);

impl AppControl for EngineControl {
    fn pause_hotkey(&self, paused: bool) {
        let _ = self.0.send(Message::PauseHotkey(paused));
    }

    fn reload_model(&self) {
        let _ = self.0.send(Message::ReloadModel);
    }
}

#[cfg(test)]
mod tests {
    use clap::Parser;

    use super::*;

    #[derive(Parser)]
    struct Command {
        #[command(flatten)]
        options: Options,
    }

    fn overrides(arguments: &[&str]) -> Map<String, Value> {
        let command = Command::try_parse_from(std::iter::once("run").chain(arguments.iter().copied())).unwrap();
        command.options.overrides().unwrap()
    }

    #[test]
    fn options_not_given_leave_the_settings_alone() {
        assert!(overrides(&[]).is_empty());
    }

    #[test]
    fn options_given_become_settings_for_the_run() {
        let given = overrides(&[
            "--key",
            "KEY_F23",
            "--no-hands-free",
            "--cleanup",
            "light",
            "--device",
            "CPU",
            "--model",
            "/srv/models/mine",
        ]);
        assert_eq!(given["dictationHotkey"], "KEY_F23");
        assert_eq!(given["handsFreeEnabled"], false);
        assert_eq!(given["cleanupLevel"], "light");
        assert_eq!(given["sttDevice"], "CPU");
        assert_eq!(given["sttModel"], "/srv/models/mine");
    }

    #[test]
    fn a_relative_model_folder_is_taken_from_where_the_app_started() {
        let given = overrides(&["--model", "models/mine"]);
        let folder = PathBuf::from(given["sttModel"].as_str().unwrap());
        assert!(folder.is_absolute());
        assert!(folder.ends_with("models/mine"));
    }
}
