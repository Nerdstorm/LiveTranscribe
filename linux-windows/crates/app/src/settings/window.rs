//! The Settings window: `ui/settings.html`, and the commands it calls. It shows the settings in
//! effect, and each control changes one at once, as the Mac's Settings does: there is no Save.
//! The page hears every change, the tray's too, and how dictation stands.

use std::fs;
use std::path::Path;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use lt_capture::input_devices;
use lt_dictation_ui::Theme;
use lt_hotkey::{KeyTracker, display_name, key_code, key_name};
use lt_shared::CleanupLevel;
use lt_transcription::qwen3_asr::inspect_model;
use serde::Serialize;
use serde_json::{Map, Value};
use tauri::ipc::Invoke;
use tauri::{AppHandle, Emitter, Manager, State, WebviewUrl, WebviewWindowBuilder, WindowEvent};

use super::model::{ADVANCED_KEYS, DEVICES, Settings};
use super::service::SettingsService;
use crate::paths;

/// The window's label, which Tauri knows it by.
const LABEL: &str = "settings";

/// What the window asks of dictation besides changing settings.
pub(crate) trait AppControl: Send + Sync {
    /// While Settings records a shortcut, the hotkey and Esc mean nothing.
    fn pause_hotkey(&self, paused: bool);
    /// Loads the speech model again, after it failed.
    fn reload_model(&self);
}

/// What Tauri keeps for the window's commands.
pub(crate) struct WindowState {
    settings: Arc<SettingsService>,
    control: Box<dyn AppControl>,
    /// How dictation stands, for a window that opens later.
    status: Mutex<Option<StatusView>>,
}

impl WindowState {
    pub(crate) fn new(settings: Arc<SettingsService>, control: Box<dyn AppControl>) -> Self {
        Self {
            settings,
            control,
            status: Mutex::new(None),
        }
    }
}

/// How dictation stands, as the window shows it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct StatusView {
    /// `downloading`, `loading`, `ready` or `failed`.
    pub(crate) model: &'static str,
    /// How far the download has got, where the model's passes run, or why it couldn't load.
    pub(crate) detail: Option<String>,
}

/// Tells an open window, and one opened later, how dictation stands.
pub(crate) fn show_status(app: &AppHandle, view: StatusView) {
    let state = app.state::<WindowState>();
    *lock(&state.status) = Some(view.clone());
    if let Err(error) = app.emit_to(LABEL, "status", view) {
        tracing::warn!("Couldn't tell the Settings window how dictation stands: {error}");
    }
}

/// Opens the Settings window, or brings it forward.
pub(crate) fn open_window(app: &AppHandle) -> tauri::Result<()> {
    if let Some(window) = app.get_webview_window(LABEL) {
        window.unminimize()?;
        window.show()?;
        return window.set_focus();
    }
    let theme = match Theme::detect() {
        Theme::Dark => tauri::Theme::Dark,
        Theme::Light => tauri::Theme::Light,
    };
    let window = WebviewWindowBuilder::new(app, LABEL, WebviewUrl::App("settings.html".into()))
        .title("Live Transcribe Settings")
        .inner_size(720.0, 680.0)
        .min_inner_size(520.0, 420.0)
        .theme(Some(theme))
        .build()?;
    let handle = app.clone();
    window.on_window_event(move |event| {
        if matches!(event, WindowEvent::Destroyed) {
            // A shortcut being recorded when the window closed isn't.
            handle.state::<WindowState>().control.pause_hotkey(false);
        }
    });
    Ok(())
}

/// Keeps an open window up to date with every change, the tray's too.
pub(crate) fn follow_changes(app: &AppHandle, settings: &SettingsService) {
    let handle = app.clone();
    settings.subscribe(move |settings, overridden| {
        if let Err(error) = handle.emit_to(LABEL, "settings", Snapshot::new(settings, overridden)) {
            tracing::warn!("Couldn't show the changed settings in the Settings window: {error}");
        }
    });
}

/// The commands the page calls.
pub(crate) fn commands() -> impl Fn(Invoke) -> bool + Send + Sync + 'static {
    tauri::generate_handler![
        settings_snapshot,
        change_settings,
        microphones,
        models,
        describe_hotkey,
        pause_hotkey,
        reload_model,
        dictation_status,
    ]
}

/// Everything the page shows about the settings.
#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct Snapshot {
    settings: Settings,
    /// For Restore Defaults, and for saying which choice is the default.
    defaults: Settings,
    /// Keys the command line sets for this run: the next start sets them again.
    overridden: Vec<String>,
    advanced_keys: [&'static str; 2],
    /// The hotkey as people say it ("Right Ctrl").
    hotkey_name: String,
    cleanup_levels: Vec<CleanupChoice>,
    devices: [&'static str; 4],
    default_model: &'static str,
    /// `dark` or `light`, as the desktop is.
    theme: &'static str,
}

#[derive(Clone, Serialize)]
struct CleanupChoice {
    id: &'static str,
    name: &'static str,
    summary: &'static str,
}

impl Snapshot {
    fn new(settings: &Settings, overridden: &[String]) -> Self {
        Self {
            hotkey_name: key_code(&settings.dictation_hotkey)
                .map(display_name)
                .unwrap_or_else(|| settings.dictation_hotkey.clone()),
            settings: settings.clone(),
            defaults: Settings::default(),
            overridden: overridden.to_vec(),
            advanced_keys: ADVANCED_KEYS,
            cleanup_levels: CleanupLevel::ALL
                .into_iter()
                .map(|level| CleanupChoice {
                    id: level.as_str(),
                    name: level.display_name(),
                    summary: level.summary(),
                })
                .collect(),
            devices: DEVICES,
            default_model: paths::DEFAULT_MODEL,
            theme: match Theme::detect() {
                Theme::Dark => "dark",
                Theme::Light => "light",
            },
        }
    }
}

#[tauri::command]
async fn settings_snapshot(state: State<'_, WindowState>) -> Result<Snapshot, String> {
    let (settings, overridden) = state.settings.current();
    Ok(Snapshot::new(&settings, &overridden))
}

/// Makes `changes` (keys and values, as `settings.json` has them) and saves them, or says why not.
#[tauri::command]
async fn change_settings(state: State<'_, WindowState>, changes: Map<String, Value>) -> Result<Snapshot, String> {
    state.settings.change(&changes).inspect_err(|error| {
        tracing::warn!("A change from the Settings window was refused: {error}");
    })?;
    let (settings, overridden) = state.settings.current();
    Ok(Snapshot::new(&settings, &overridden))
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct MicrophoneList {
    microphones: Vec<Microphone>,
    /// The system's default input, one of `microphones`.
    default_id: Option<String>,
}

#[derive(Serialize)]
struct Microphone {
    id: String,
    name: String,
}

/// The microphones connected now. Asking the sound server can take a moment, so it is asked off
/// the window's thread.
#[tauri::command]
async fn microphones() -> Result<MicrophoneList, String> {
    let devices = tauri::async_runtime::spawn_blocking(input_devices)
        .await
        .map_err(|error| error.to_string())?
        .map_err(|error| error.to_string())?;
    Ok(MicrophoneList {
        microphones: devices
            .devices
            .into_iter()
            .map(|device| Microphone {
                id: device.id,
                name: device.name,
            })
            .collect(),
        default_id: devices.default,
    })
}

#[derive(Serialize)]
struct ModelList {
    /// Where the setup kit converts models to.
    folder: String,
    models: Vec<ModelEntry>,
}

#[derive(Debug, PartialEq, Eq, Serialize)]
struct ModelEntry {
    /// Its folder's name, which `sttModel` keeps.
    name: String,
    /// The checkpoint it was converted from, without the revision.
    source: String,
    /// Why this build can't run it, if it can't.
    problem: Option<String>,
}

/// The models converted on this machine: each folder in the models folder with a manifest.
#[tauri::command]
async fn models() -> Result<ModelList, String> {
    let folder = paths::models_folder().map_err(|error| format!("{error:#}"))?;
    Ok(ModelList {
        models: models_in(&folder),
        folder: folder.display().to_string(),
    })
}

fn models_in(folder: &Path) -> Vec<ModelEntry> {
    let Ok(entries) = fs::read_dir(folder) else {
        return Vec::new();
    };
    let mut models: Vec<ModelEntry> = entries
        .filter_map(Result::ok)
        .filter_map(|entry| {
            let summary = inspect_model(&entry.path())?;
            Some(ModelEntry {
                name: entry.file_name().to_string_lossy().into_owned(),
                source: summary
                    .source
                    .split_once('@')
                    .map_or(summary.source.as_str(), |(repository, _)| repository)
                    .to_owned(),
                problem: summary.problem,
            })
        })
        .collect();
    models.sort_by(|a, b| a.name.cmp(&b.name));
    models
}

/// The hotkey `name` (as linux/input-event-codes.h has it) as people say it, or why it can't be
/// the hotkey: for the shortcut recorder, before it changes the setting.
#[tauri::command]
async fn describe_hotkey(name: String) -> Result<HotkeyDescription, String> {
    let code = key_code(&name).ok_or_else(|| format!("{name} isn't a key this app knows"))?;
    KeyTracker::new(code).map_err(|reason| reason.to_string())?;
    Ok(HotkeyDescription {
        name: key_name(code),
        display_name: display_name(code),
    })
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct HotkeyDescription {
    name: String,
    display_name: String,
}

#[tauri::command]
async fn pause_hotkey(state: State<'_, WindowState>, paused: bool) -> Result<(), String> {
    state.control.pause_hotkey(paused);
    Ok(())
}

#[tauri::command]
async fn reload_model(state: State<'_, WindowState>) -> Result<(), String> {
    state.control.reload_model();
    Ok(())
}

#[tauri::command]
async fn dictation_status(state: State<'_, WindowState>) -> Result<Option<StatusView>, String> {
    Ok(lock(&state.status).clone())
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn models_are_the_folders_with_a_manifest() {
        let folder = std::env::temp_dir().join(format!("lt-models-{}", std::process::id()));
        let _ = fs::remove_dir_all(&folder);
        assert!(models_in(&folder).is_empty(), "no models folder yet");
        for (name, manifest) in [
            (
                "qwen3-asr-0.6b-sinhala",
                Some(r#"{"format": 2, "model": "qwen3-asr", "source": "Nerdstorm/Qwen3-ASR-0.6B-Sinhala-8bit@c123"}"#),
            ),
            ("downloads", None),
            (
                "qwen3-asr-0.6b",
                Some(r#"{"format": 1, "model": "qwen3-asr", "source": "Qwen/Qwen3-ASR-0.6B@5eb1"}"#),
            ),
        ] {
            fs::create_dir_all(folder.join(name)).unwrap();
            if let Some(manifest) = manifest {
                fs::write(folder.join(name).join("manifest.json"), manifest).unwrap();
            }
        }
        let models = models_in(&folder);
        let names: Vec<_> = models.iter().map(|model| model.name.as_str()).collect();
        assert_eq!(names, ["qwen3-asr-0.6b", "qwen3-asr-0.6b-sinhala"]);
        assert_eq!(models[0].source, "Qwen/Qwen3-ASR-0.6B");
        assert!(models[0].problem.is_some(), "an old format");
        assert_eq!(models[1].source, "Nerdstorm/Qwen3-ASR-0.6B-Sinhala-8bit");
        let _ = fs::remove_dir_all(folder);
    }
}
