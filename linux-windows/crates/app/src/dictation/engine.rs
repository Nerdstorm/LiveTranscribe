//! The dictation engine, on a thread of its own. It feeds the controller what happens (the
//! hotkey, the menu, changed settings, the workers' results) in the order it happens, with times
//! from one clock, and runs the gesture's and the panel's timers. It loads the speech model, and
//! loads another when Settings chooses one, once no dictation is under way: at once if the model
//! it was loading is still downloading, which carries on in Settings › Models. It loads cleanup's
//! language model too while Settings › Advanced has it on, and lets it go when it's turned off.
//! After each, the tray and the Settings window hear how things stand, when that has changed.

use std::sync::Arc;
use std::sync::mpsc::{Receiver, RecvTimeoutError, Sender};
use std::thread;
use std::time::Duration;

use lt_capture::Recorder;
use lt_cleanup::CleanedText;
use lt_dictation::{DictationController, Job, Phase};
use lt_dictation_ui::{Blocker, ModelState, PanelModel};
use lt_hotkey::{HotkeyEvent, HotkeyWatch, display_name, key_code};
use lt_insertion::Inserted;
use lt_shared::CleanupLevel;
use tauri::AppHandle;

use super::cleaner::CleanupModelSlot;
use super::configuration::{self, ModelChoice};
use super::desktop::Desktop;
use super::platform::{Clock, Platform};
use super::transcriber::{Jobs, Transcriber};
use crate::settings::Settings;
use crate::speech_models::{ChosenModel, Progress, SpeechModelLibrary, Stage};

pub(crate) enum Message {
    Hotkey(HotkeyEvent),
    Menu(MenuCommand),
    /// The settings changed: the ones now in effect.
    Settings(Box<Settings>),
    /// Settings is recording a new shortcut, so the hotkey and Esc mean nothing until it stops.
    PauseHotkey(bool),
    /// Settings asks for the speech model to be loaded again, after it failed.
    ReloadModel,
    /// How far downloading the speech model (or unpacking or checking it) has got, before it loads.
    ModelDownload {
        generation: u64,
        progress: Progress,
    },
    /// The speech model loaded (where its passes run), or couldn't.
    ModelLoaded {
        generation: u64,
        result: Result<String, String>,
    },
    Transcribed {
        job: Job,
        result: Result<String, String>,
    },
    /// Settings asks for the cleanup model to be loaded again, after it failed.
    ReloadCleanupModel,
    /// How far downloading (or checking) the cleanup model has got, before it loads.
    CleanupDownload {
        generation: u64,
        progress: Progress,
    },
    /// The cleanup model loaded (where it runs, and with which adapters), or couldn't.
    CleanupLoaded {
        generation: u64,
        result: Result<String, String>,
    },
    Cleaned {
        job: Job,
        cleaned: CleanedText,
    },
    Inserted {
        job: Job,
        result: Result<Inserted, String>,
    },
}

/// What the tray's menu asks for: *Start* or *Stop Dictation*, *Cancel Dictation* and *Copy Last
/// Dictation*.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum MenuCommand {
    Toggle,
    Cancel,
    CopyLast,
}

/// How dictation stands, for the tray and the Settings window.
#[derive(Clone, Debug, PartialEq)]
pub(crate) struct DictationStatus {
    pub(crate) phase: Phase,
    pub(crate) model: ModelState,
    /// The model loading, loaded or that failed: its catalog id, if it has one, and its name.
    pub(crate) model_id: Option<String>,
    pub(crate) model_name: Option<String>,
    /// How far its download (or unpacking or checking) has got, while that's under way.
    pub(crate) download: Option<Progress>,
    /// Where the loaded model's passes run.
    pub(crate) placement: Option<String>,
    /// The hotkey's name as people say it, or `None` while dictation is turned off.
    pub(crate) hotkey: Option<String>,
    pub(crate) has_last_dictation: bool,
    pub(crate) cleanup: CleanupLevel,
    /// Cleanup's language model: `None` while it's turned off in Settings › Advanced.
    pub(crate) cleanup_model: Option<CleanupModelStatus>,
    /// Why dictation can't start at all; the engine never runs then.
    pub(crate) blocker: Option<Blocker>,
}

/// How cleanup's language model stands.
#[derive(Clone, Debug, PartialEq)]
pub(crate) struct CleanupModelStatus {
    pub(crate) state: ModelState,
    /// How far its download (or checking) has got, while that's under way.
    pub(crate) download: Option<Progress>,
    /// Where it runs, and with which adapters, once loaded.
    pub(crate) placement: Option<String>,
}

/// Where the engine tells how things stand.
pub(crate) type StatusSink = Box<dyn Fn(&DictationStatus) + Send>;

pub(crate) struct Engine {
    pub(crate) settings: Settings,
    /// The catalog's models, which Settings › Models shares.
    pub(crate) library: Arc<SpeechModelLibrary>,
    pub(crate) hotkey: HotkeyWatch,
    pub(crate) recorder: Recorder,
    pub(crate) desktop: Box<dyn Desktop>,
    pub(crate) messages: Sender<Message>,
    pub(crate) received: Receiver<Message>,
}

impl Engine {
    /// The app's windows are up, for a desktop that shows the panel in one of them.
    pub(crate) fn attach(&self, app: &AppHandle) {
        self.desktop.attach(app);
    }

    /// Runs the engine on a thread of its own, telling how things stand through `status`.
    pub(crate) fn start(self, status: StatusSink) {
        let spawned = thread::Builder::new()
            .name("dictation".to_owned())
            .spawn(move || self.run(status));
        if let Err(error) = spawned {
            eprintln!("livetranscribe: couldn't start dictation: {error}");
        }
    }

    fn run(self, status: StatusSink) {
        let clock = Clock::start();
        let platform = Platform::new(
            self.recorder,
            self.desktop,
            self.messages.clone(),
            PanelModel::new(configuration::notice_ms(&self.settings)),
            &self.settings,
            clock,
        );
        let mut running = Running {
            controller: DictationController::new(configuration::controller(&self.settings), platform),
            hotkey_name: hotkey_name(&self.settings),
            settings: self.settings,
            library: self.library,
            hotkey: self.hotkey,
            hotkey_paused: false,
            model: Model::Failed {
                choice: None,
                error: "not loaded yet".to_owned(),
            },
            generation: 0,
            reload: false,
            cleanup: CleanupModelSlot::default(),
            messages: self.messages,
            status,
            shown: None,
            clock,
        };
        running.load_model();
        running.load_cleanup_model_if_changed();
        running.dictate(&self.received);
    }
}

/// The speech model: loading, loaded, or not.
enum Model {
    Loading {
        choice: ModelChoice,
        /// Tells this load's answer from an earlier one's.
        generation: u64,
        /// How far downloading the model has got, while it downloads.
        download: Option<Progress>,
        transcriber: Transcriber,
        jobs: Jobs,
    },
    Ready {
        choice: ModelChoice,
        transcriber: Transcriber,
        placement: String,
    },
    Failed {
        /// `None` when the settings named no folder that could be looked for.
        choice: Option<ModelChoice>,
        error: String,
    },
}

impl Model {
    fn choice(&self) -> Option<&ModelChoice> {
        match self {
            Self::Loading { choice, .. } | Self::Ready { choice, .. } => Some(choice),
            Self::Failed { choice, .. } => choice.as_ref(),
        }
    }

    /// How far the download (or unpacking or checking) of the model loading has got, while that's
    /// under way: once it's done, the model is loading.
    fn download(&self) -> Option<Progress> {
        match self {
            Self::Loading { download, .. } => download.filter(|progress| progress.done < progress.total),
            _ => None,
        }
    }

    fn state(&self) -> ModelState {
        match self {
            Self::Loading { .. } => ModelState::Loading {
                percent: self
                    .download()
                    .filter(|progress| progress.stage == Stage::Downloading)
                    .map(Progress::percent),
            },
            Self::Ready { .. } => ModelState::Ready,
            Self::Failed { error, .. } => ModelState::Failed(error.clone()),
        }
    }
}

struct Running {
    controller: DictationController<Platform>,
    settings: Settings,
    library: Arc<SpeechModelLibrary>,
    hotkey: HotkeyWatch,
    /// The hotkey's name as people say it.
    hotkey_name: String,
    hotkey_paused: bool,
    model: Model,
    generation: u64,
    /// Load the model again even if the settings still choose it.
    reload: bool,
    cleanup: CleanupModelSlot,
    messages: Sender<Message>,
    status: StatusSink,
    /// What the tray was last told.
    shown: Option<DictationStatus>,
    clock: Clock,
}

impl Running {
    /// Feeds the controller until every sender has gone.
    fn dictate(&mut self, messages: &Receiver<Message>) {
        loop {
            self.report();
            let deadline = [
                self.controller.next_timer(),
                self.controller.dependencies().panel_deadline(),
            ]
            .into_iter()
            .flatten()
            .min();
            let message = match deadline {
                Some(deadline) => {
                    let now = self.clock.now_ms();
                    if deadline <= now {
                        if self.controller.next_timer().is_some_and(|timer| timer <= now) {
                            self.controller.timer_fired(now);
                        }
                        self.controller.dependencies_mut().advance_panel(now);
                        continue;
                    }
                    match messages.recv_timeout(Duration::from_millis(deadline - now)) {
                        Ok(message) => message,
                        Err(RecvTimeoutError::Timeout) => continue,
                        Err(RecvTimeoutError::Disconnected) => return,
                    }
                }
                None => match messages.recv() {
                    Ok(message) => message,
                    Err(_) => return,
                },
            };
            self.handle(message);
            self.load_model_if_changed();
            self.load_cleanup_model_if_changed();
        }
    }

    fn handle(&mut self, message: Message) {
        let now = self.clock.now_ms();
        match message {
            // Keys pressed while dictation is off, Settings records a shortcut, or no model is
            // loaded are not a dictation.
            Message::Hotkey(event) => {
                if self.settings.dictation_enabled && !self.hotkey_paused && matches!(self.model, Model::Ready { .. }) {
                    self.controller.hotkey(event, now);
                }
            }
            Message::Menu(MenuCommand::Toggle) => self.controller.toggle_dictation(now),
            Message::Menu(MenuCommand::Cancel) => self.controller.cancel(),
            Message::Menu(MenuCommand::CopyLast) => {
                if let Some(text) = self.controller.last_text().map(str::to_owned) {
                    eprintln!("Copied the last dictation ({} characters)", text.chars().count());
                    self.controller.dependencies().copy(text);
                }
            }
            Message::Settings(settings) => self.apply(*settings),
            Message::PauseHotkey(paused) => {
                if paused == self.hotkey_paused {
                    return;
                }
                self.hotkey.set_paused(paused);
                self.hotkey_paused = paused;
                // A dictation can't go on while its key means nothing, as on the Mac.
                if paused && self.controller.is_recording() {
                    self.controller.cancel();
                }
            }
            Message::ReloadModel => {
                // A load under way is already a fresh try.
                if !matches!(self.model, Model::Loading { .. }) {
                    self.reload = true;
                }
            }
            Message::ModelDownload { generation, progress } => {
                if let Model::Loading {
                    generation: loading,
                    download,
                    ..
                } = &mut self.model
                    && *loading == generation
                {
                    *download = Some(progress);
                }
            }
            Message::ModelLoaded { generation, result } => self.model_loaded(generation, result),
            Message::Transcribed { job, result } => self.controller.transcribed(job, result),
            Message::ReloadCleanupModel => self.cleanup.try_again(),
            Message::CleanupDownload { generation, progress } => self.cleanup.downloading(generation, progress),
            Message::CleanupLoaded { generation, result } => {
                if let Some(jobs) = self.cleanup.loaded(generation, result) {
                    self.controller.dependencies_mut().set_cleaner(Some(jobs));
                }
            }
            Message::Cleaned { job, cleaned } => self.controller.cleaned(job, cleaned),
            Message::Inserted { job, result } => self.controller.inserted(job, result, now),
        }
    }

    /// Takes changed settings: each part uses them from its next dictation, gesture, message
    /// or paste. A recording held on a hotkey that has changed or been turned off is cancelled,
    /// since its release would mean nothing.
    fn apply(&mut self, settings: Settings) {
        let before = std::mem::replace(&mut self.settings, settings);
        let after = &self.settings;
        let mut cancel = false;
        if before.dictation_hotkey != after.dictation_hotkey {
            match key_code(&after.dictation_hotkey).map(|code| self.hotkey.set_hotkey(code)) {
                Some(Ok(())) => {
                    self.hotkey_name = hotkey_name(after);
                    eprintln!("Dictation hotkey: {}", self.hotkey_name);
                    cancel = true;
                }
                Some(Err(reason)) => eprintln!("⚠ The hotkey stays {}: {reason}", self.hotkey_name),
                None => eprintln!(
                    "⚠ The hotkey stays {}: {} isn't a key",
                    self.hotkey_name, after.dictation_hotkey
                ),
            }
        }
        if before.dictation_enabled != after.dictation_enabled {
            if after.dictation_enabled {
                eprintln!("Dictation is on: hold {} and speak", self.hotkey_name);
            } else {
                eprintln!("Dictation is off: the hotkey does nothing until it is turned on in Settings");
                cancel = true;
            }
        }
        if before.cleanup_level != after.cleanup_level {
            eprintln!("Cleanup: {}", after.cleanup_level.display_name());
        }
        if before.cleanup_enabled != after.cleanup_enabled {
            if after.cleanup_enabled {
                eprintln!("Cleanup's language model is on");
            } else {
                eprintln!("Cleanup's language model is off: each level applies only its rules that need no model");
            }
        }
        if before.stt_language != after.stt_language {
            let catalog = self.library.catalog();
            match after
                .stt_language
                .as_deref()
                .and_then(|code| catalog.language_named(code))
            {
                Some(choice) => eprintln!("Language: {}", choice.name),
                None => eprintln!("Language: the speech model's default"),
            }
        }
        if cancel && self.controller.is_recording() {
            self.controller.cancel();
        }
        self.controller.set_configuration(configuration::controller(after));
        self.controller.dependencies_mut().configure(after);
    }

    /// The model the settings choose now.
    fn wanted(&self) -> ModelChoice {
        ModelChoice::from_settings(
            &self.settings,
            self.library.catalog(),
            self.library.downloads().folder(),
        )
    }

    /// Starts loading the model the settings choose.
    fn load_model(&mut self) {
        self.generation += 1;
        let choice = self.wanted();
        let loading = Transcriber::load(
            choice.clone(),
            self.generation,
            self.messages.clone(),
            Arc::clone(&self.library),
        );
        self.model = match loading {
            Ok((transcriber, jobs)) => Model::Loading {
                choice,
                generation: self.generation,
                download: None,
                transcriber,
                jobs,
            },
            Err(error) => Model::Failed {
                choice: Some(choice),
                error: format!("{error:#}"),
            },
        };
        if let Model::Failed { error, .. } = &self.model {
            eprintln!("livetranscribe: {error}");
        }
    }

    fn model_loaded(&mut self, generation: u64, result: Result<String, String>) {
        if !matches!(&self.model, Model::Loading { generation: loading, .. } if *loading == generation) {
            return;
        }
        let failed = Model::Failed {
            choice: None,
            error: String::new(),
        };
        let Model::Loading {
            choice,
            transcriber,
            jobs,
            ..
        } = std::mem::replace(&mut self.model, failed)
        else {
            return;
        };
        self.model = match result {
            Ok(placement) => {
                self.controller.dependencies_mut().set_transcriber(Some(jobs));
                eprintln!(
                    "Ready. Hold {} and speak; release to type the text.{} Esc cancels. Quit from the tray, \
                     or with Ctrl+C here.",
                    self.hotkey_name,
                    if self.settings.hands_free_enabled {
                        " Tap it twice to keep recording hands-free until you press it again."
                    } else {
                        ""
                    }
                );
                Model::Ready {
                    choice,
                    transcriber,
                    placement,
                }
            }
            Err(error) => {
                eprintln!("livetranscribe: {error}");
                drop(jobs);
                transcriber.finish();
                Model::Failed {
                    choice: Some(choice),
                    error,
                }
            }
        };
    }

    /// Loads the model the settings choose now, if it isn't the one loaded (or loading, or that
    /// failed) or a reload was asked for, once nothing is being dictated: the model in use goes
    /// first, so the two are never on the device together. A model still downloading is left to
    /// download; one that has started loading loads first.
    fn load_model_if_changed(&mut self) {
        if !self.controller.is_idle() {
            return;
        }
        let wanted = self.wanted();
        if let Model::Loading { choice, .. } = &self.model
            && (*choice == wanted || self.model.download().is_none())
        {
            return;
        }
        let reload = std::mem::take(&mut self.reload);
        if Some(&wanted) == self.model.choice() && !reload {
            return;
        }
        self.controller.dependencies_mut().set_transcriber(None);
        let unloading = Model::Failed {
            choice: None,
            error: String::new(),
        };
        match std::mem::replace(&mut self.model, unloading) {
            Model::Ready { transcriber, .. } => transcriber.finish(),
            Model::Loading { transcriber, jobs, .. } => {
                transcriber.abandon();
                drop(jobs);
                transcriber.finish();
            }
            Model::Failed { .. } => {}
        }
        self.load_model();
    }

    /// Loads cleanup's language model while the settings have it on, and lets it go once they
    /// don't, when no dictation is under way.
    fn load_cleanup_model_if_changed(&mut self) {
        if !self.controller.is_idle() {
            return;
        }
        let wanted = self.settings.cleanup_enabled;
        // The platform's sender goes before the model's thread is waited for, which ends only
        // once every sender has.
        let platform = self.controller.dependencies_mut();
        self.cleanup.want(wanted, &self.messages, || platform.set_cleaner(None));
    }

    /// Tells the tray how things stand, when that has changed.
    fn report(&mut self) {
        let choice = self.model.choice();
        let status = DictationStatus {
            phase: self.controller.phase(),
            model: self.model.state(),
            model_id: choice.and_then(|choice| match &choice.model {
                ChosenModel::Catalog(model) => Some(model.id.clone()),
                ChosenModel::Converted(_) => None,
            }),
            model_name: choice.map(|choice| choice.model.name()),
            download: self.model.download(),
            placement: match &self.model {
                Model::Ready { placement, .. } => Some(placement.clone()),
                _ => None,
            },
            hotkey: self.settings.dictation_enabled.then(|| self.hotkey_name.clone()),
            has_last_dictation: self.controller.last_text().is_some(),
            cleanup: self.controller.cleanup_level(),
            cleanup_model: self.cleanup.status(),
            blocker: None,
        };
        if self.shown.as_ref() != Some(&status) {
            (self.status)(&status);
            self.shown = Some(status);
        }
    }
}

fn hotkey_name(settings: &Settings) -> String {
    key_code(&settings.dictation_hotkey)
        .map(display_name)
        .unwrap_or_else(|| settings.dictation_hotkey.clone())
}
