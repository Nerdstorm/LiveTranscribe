//! The Settings window: `ui/settings.html`, and the commands it calls. It shows the settings in
//! effect, and each control changes one at once, as the Mac's Settings does: there is no Save.
//! The page hears every change, the tray's too, how dictation stands, and how each speech model's
//! download goes (Settings › Models).

use std::fs;
use std::path::Path;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use lt_capture::input_devices;
use lt_dictation_ui::Theme;
use lt_hotkey::{KeyTracker, display_name, key_code, key_name};
use lt_shared::CleanupLevel;
use lt_transcription::catalog::{Engine, LanguageChoice, SpeechModel};
use lt_transcription::qwen3_asr::inspect_model;
use serde::Serialize;
use serde_json::{Map, Value};
use tauri::ipc::Invoke;
use tauri::{AppHandle, Emitter, Manager, State, WebviewUrl, WebviewWindowBuilder, WindowEvent};

use super::model::{ADVANCED_KEYS, DEVICES, Settings};
use super::service::SettingsService;
use crate::speech_models::{DEFAULT_MODEL, DownloadState, SpeechModelLibrary, Stage};

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
    library: Arc<SpeechModelLibrary>,
    control: Box<dyn AppControl>,
    /// How dictation stands, for a window that opens later.
    status: Mutex<Option<StatusView>>,
}

impl WindowState {
    pub(crate) fn new(
        settings: Arc<SettingsService>,
        library: Arc<SpeechModelLibrary>,
        control: Box<dyn AppControl>,
    ) -> Self {
        Self {
            settings,
            library,
            control,
            status: Mutex::new(None),
        }
    }
}

/// How dictation stands, as the window shows it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct StatusView {
    /// `downloading`, `unpacking`, `checking`, `loading`, `ready` or `failed`; `idle` while
    /// dictation can't start.
    pub(crate) model: &'static str,
    /// How far the download has got, where the model's passes run, or why it couldn't load.
    pub(crate) detail: Option<String>,
    /// The catalog id of the model it's about; `None` for a folder the setup kit converted.
    pub(crate) model_id: Option<String>,
    /// How far downloading, unpacking or checking it has got.
    pub(crate) percent: Option<u8>,
    /// Why dictation can't start at all, if it can't.
    pub(crate) blocker: Option<BlockerView>,
}

/// Why dictation can't start, as the top of the window says it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub(crate) struct BlockerView {
    pub(crate) title: &'static str,
    pub(crate) detail: String,
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

/// Keeps an open window up to date with every change, the tray's too, and with each download.
pub(crate) fn follow_changes(app: &AppHandle, settings: &SettingsService, library: &Arc<SpeechModelLibrary>) {
    let handle = app.clone();
    settings.subscribe(move |settings, overridden| {
        if let Err(error) = handle.emit_to(LABEL, "settings", Snapshot::new(settings, overridden)) {
            tracing::warn!("Couldn't show the changed settings in the Settings window: {error}");
        }
    });
    let handle = app.clone();
    let weak = Arc::downgrade(library);
    library.subscribe(move |model, state| {
        let Some(library) = weak.upgrade() else { return };
        let view = CatalogModelView::new(model, state, &library);
        if let Err(error) = handle.emit_to(LABEL, "speech-model", view) {
            tracing::warn!("Couldn't show how a download goes in the Settings window: {error}");
        }
    });
}

/// The commands the page calls.
pub(crate) fn commands() -> impl Fn(Invoke) -> bool + Send + Sync + 'static {
    tauri::generate_handler![
        settings_snapshot,
        change_settings,
        microphones,
        speech_models,
        download_model,
        cancel_download,
        remove_model,
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
    advanced_keys: [&'static str; 1],
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
            default_model: DEFAULT_MODEL,
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

/// Settings › Models: the catalog's models, and the models the setup kit converted.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct SpeechModelsView {
    /// The models folder: where downloads go, and the setup kit converts models to.
    folder: String,
    models: Vec<CatalogModelView>,
    converted: Vec<ConvertedModel>,
}

/// A catalog model, and how its download stands.
#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct CatalogModelView {
    id: String,
    name: String,
    summary: String,
    languages: String,
    licence: String,
    credit: String,
    /// How much a download fetches, and from where.
    bytes: u64,
    source: &'static str,
    /// Whether it runs on the CPU whatever the device setting says.
    cpu_only: bool,
    /// The languages it can be told to write, its default first; empty for a model that finds
    /// the language itself.
    language_choices: Vec<LanguageChoice>,
    download: DownloadView,
    /// Some of its files are here and it isn't downloading.
    can_remove: bool,
}

impl CatalogModelView {
    fn new(model: &SpeechModel, state: &DownloadState, library: &SpeechModelLibrary) -> Self {
        Self {
            id: model.id.clone(),
            name: model.name.clone(),
            summary: model.summary.clone(),
            languages: model.languages.clone(),
            licence: model.licence.clone(),
            credit: model.credit.clone(),
            bytes: model.download_bytes(),
            source: model.source(),
            cpu_only: !matches!(model.engine, Engine::OpenVino { .. }),
            language_choices: model.language_choices.clone(),
            download: DownloadView::new(state),
            can_remove: library.can_remove(model),
        }
    }
}

/// A download's state, as the page shows it.
#[derive(Clone, Serialize)]
#[serde(tag = "state", rename_all = "camelCase")]
enum DownloadView {
    NotDownloaded,
    /// `stage` is `downloading`, `unpacking` or `checking`.
    Downloading {
        stage: &'static str,
        percent: u8,
    },
    Downloaded,
    Failed {
        problem: String,
    },
}

impl DownloadView {
    fn new(state: &DownloadState) -> Self {
        match state {
            DownloadState::NotDownloaded => Self::NotDownloaded,
            DownloadState::Downloading(progress) => Self::Downloading {
                stage: match progress.stage {
                    Stage::Downloading => "downloading",
                    Stage::Unpacking => "unpacking",
                    Stage::Checking => "checking",
                },
                percent: progress.percent(),
            },
            DownloadState::Downloaded => Self::Downloaded,
            DownloadState::Failed(problem) => Self::Failed {
                problem: problem.clone(),
            },
        }
    }
}

/// A model the setup kit converted into the models folder.
#[derive(Debug, PartialEq, Eq, Serialize)]
struct ConvertedModel {
    /// Its folder's name, which `sttModel` keeps.
    name: String,
    /// The checkpoint it was converted from, without the revision.
    source: String,
    /// Why this build can't run it, if it can't.
    problem: Option<String>,
}

#[tauri::command]
async fn speech_models(state: State<'_, WindowState>) -> Result<SpeechModelsView, String> {
    let library = &state.library;
    let folder = library.downloads().folder();
    let catalog = library.catalog();
    Ok(SpeechModelsView {
        folder: folder.display().to_string(),
        models: catalog
            .models()
            .iter()
            .map(|model| CatalogModelView::new(model, &library.state(model), library))
            .collect(),
        converted: converted_in(folder, |name| catalog.model(name).is_some()),
    })
}

/// The catalog model `id`, or why there's none.
fn catalog_model(library: &SpeechModelLibrary, id: &str) -> Result<&'static SpeechModel, String> {
    library
        .catalog()
        .model(id)
        .ok_or_else(|| format!("there is no speech model {id}"))
}

#[tauri::command]
async fn download_model(state: State<'_, WindowState>, id: String) -> Result<(), String> {
    let model = catalog_model(&state.library, &id)?;
    tracing::info!("Download of {id} asked for in Settings");
    state.library.download(model);
    Ok(())
}

#[tauri::command]
async fn cancel_download(state: State<'_, WindowState>, id: String) -> Result<(), String> {
    let model = catalog_model(&state.library, &id)?;
    state.library.cancel(model);
    Ok(())
}

/// Removes a model's files, unless it's the one chosen or in use.
#[tauri::command]
async fn remove_model(state: State<'_, WindowState>, id: String) -> Result<(), String> {
    let model = catalog_model(&state.library, &id)?;
    let chosen = state.settings.current().0.stt_model;
    if chosen.as_deref().unwrap_or(DEFAULT_MODEL) == id {
        return Err(format!("{} is the model chosen: choose another first", model.name));
    }
    if lock(&state.status)
        .as_ref()
        .is_some_and(|status| status.model_id.as_deref() == Some(id.as_str()))
    {
        return Err(format!("{} is in use until the model chosen loads", model.name));
    }
    let library = Arc::clone(&state.library);
    tauri::async_runtime::spawn_blocking(move || library.remove(model))
        .await
        .map_err(|error| error.to_string())?
}

/// The models converted into `folder`: each folder in it with a manifest, but for the catalog's,
/// which `is_catalogs` names, and downloads under way.
fn converted_in(folder: &Path, is_catalogs: impl Fn(&str) -> bool) -> Vec<ConvertedModel> {
    let Ok(entries) = fs::read_dir(folder) else {
        return Vec::new();
    };
    let mut models: Vec<ConvertedModel> = entries
        .filter_map(Result::ok)
        .filter_map(|entry| {
            let name = entry.file_name().to_string_lossy().into_owned();
            if name.starts_with('.') || is_catalogs(&name) {
                return None;
            }
            let summary = inspect_model(&entry.path())?;
            Some(ConvertedModel {
                name,
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
    fn every_key_the_page_records_is_one_this_system_knows() {
        // The page names keys as linux/input-event-codes.h does, and so do the settings, on every
        // system: each name it can record must have a key code here.
        let page = include_str!("../../ui/settings.js");
        let table = &page[page.find("const KEY_NAMES").expect("the page's table of keys")..];
        let table = &table[..table.find("})();").expect("the table's end")];
        let mut names: Vec<String> = table
            .split('"')
            .skip(1)
            .step_by(2)
            .filter(|name| name.starts_with("KEY_"))
            .map(str::to_owned)
            .collect();
        assert!(names.len() > 60, "the table was read: {names:?}");
        // The names the page makes in loops.
        names.extend(('A'..='Z').map(|letter| format!("KEY_{letter}")));
        names.extend((0..=9).flat_map(|digit| [format!("KEY_{digit}"), format!("KEY_KP{digit}")]));
        names.extend((1..=24).map(|number| format!("KEY_F{number}")));
        let unknown: Vec<&String> = names.iter().filter(|name| key_code(name).is_none()).collect();
        assert!(
            unknown.is_empty(),
            "keys the page records that this system doesn't know: {unknown:?}"
        );
    }

    #[test]
    fn converted_models_are_the_folders_with_a_manifest_but_the_catalogs() {
        let folder = std::env::temp_dir().join(format!("lt-models-{}", std::process::id()));
        let _ = fs::remove_dir_all(&folder);
        assert!(converted_in(&folder, |_| false).is_empty(), "no models folder yet");
        for (name, manifest) in [
            (
                "qwen3-asr-0.6b-sinhala",
                Some(r#"{"format": 2, "model": "qwen3-asr", "source": "Nerdstorm/Qwen3-ASR-0.6B-Sinhala-8bit@c123"}"#),
            ),
            (
                ".qwen3-asr-1.7b.download",
                Some(r#"{"format": 2, "model": "qwen3-asr", "source": "Qwen/Qwen3-ASR-1.7B@aa11"}"#),
            ),
            ("downloads", None),
            (
                "qwen3-asr-0.6b",
                Some(r#"{"format": 1, "model": "qwen3-asr", "source": "Qwen/Qwen3-ASR-0.6B@5eb1"}"#),
            ),
            (
                "qwen3-asr-0.6b-v2",
                Some(concat!(
                    r#"{"format": 2, "model": "qwen3-asr", "source": "Qwen/Qwen3-ASR-0.6B@5eb1","#,
                    r#" "audio": {"mel_bins": 128, "width": 896, "output_width": 1024},"#,
                    r#" "text": {"width": 1024, "vocab_size": 151936, "audio_token_id": 151676}}"#
                )),
            ),
        ] {
            fs::create_dir_all(folder.join(name)).unwrap();
            if let Some(manifest) = manifest {
                fs::write(folder.join(name).join("manifest.json"), manifest).unwrap();
            }
        }
        let models = converted_in(&folder, |name| name == "qwen3-asr-0.6b-sinhala");
        let names: Vec<_> = models.iter().map(|model| model.name.as_str()).collect();
        assert_eq!(names, ["qwen3-asr-0.6b", "qwen3-asr-0.6b-v2"]);
        assert_eq!(models[0].source, "Qwen/Qwen3-ASR-0.6B");
        assert!(models[0].problem.is_some(), "an old format");
        assert_eq!(models[1].problem, None);
        let _ = fs::remove_dir_all(folder);
    }
}
