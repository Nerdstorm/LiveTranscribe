//! The dictation engine, on a thread of its own. It feeds the controller what happens (the
//! hotkey, the menu, changed settings, the workers' results) in the order it happens, with times
//! from one clock, and runs the gesture's and the panel's timers. It loads the speech model, and
//! loads another when Settings chooses one, once no dictation is under way.
//! After each, the tray and the Settings window hear how things stand, when that has changed.

use std::sync::mpsc::{Receiver, RecvTimeoutError, Sender};
use std::thread;
use std::time::Duration;

use lt_capture::Recorder;
use lt_dictation::{DictationController, Job, Phase};
use lt_dictation_ui::{Blocker, ModelState, PanelModel};
use lt_hotkey::{HotkeyEvent, HotkeyWatch, display_name, key_code};
use lt_insertion::Inserted;
use lt_shared::CleanupLevel;
use lt_wayland::WaylandSession;

use super::configuration::{self, ModelChoice};
use super::platform::{Clock, Platform};
use super::transcriber::{Jobs, Transcriber};
use crate::model_download::Progress;
use crate::settings::Settings;

pub(crate) enum Message {
    Hotkey(HotkeyEvent),
    Menu(MenuCommand),
    /// The settings changed: the ones now in effect.
    Settings(Box<Settings>),
    /// Settings is recording a new shortcut, so the hotkey and Esc mean nothing until it stops.
    PauseHotkey(bool),
    /// Settings asks for the speech model to be loaded again, after it failed.
    ReloadModel,
    /// How far downloading the speech model has got, before it loads.
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
    /// Where the loaded model's passes run.
    pub(crate) placement: Option<String>,
    /// The hotkey's name as people say it, or `None` while dictation is turned off.
    pub(crate) hotkey: Option<String>,
    pub(crate) has_last_dictation: bool,
    pub(crate) cleanup: CleanupLevel,
    /// Why dictation can't start at all; the engine never runs then.
    pub(crate) blocker: Option<Blocker>,
}

/// Where the engine tells how things stand.
pub(crate) type StatusSink = Box<dyn Fn(&DictationStatus) + Send>;

pub(crate) struct Engine {
    pub(crate) settings: Settings,
    pub(crate) hotkey: HotkeyWatch,
    pub(crate) recorder: Recorder,
    pub(crate) session: WaylandSession,
    pub(crate) messages: Sender<Message>,
    pub(crate) received: Receiver<Message>,
}

impl Engine {
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
            self.session,
            self.messages.clone(),
            PanelModel::new(configuration::notice_ms(&self.settings)),
            clock,
        );
        let mut running = Running {
            controller: DictationController::new(configuration::controller(&self.settings), platform),
            hotkey_name: hotkey_name(&self.settings),
            settings: self.settings,
            hotkey: self.hotkey,
            hotkey_paused: false,
            model: Model::Failed {
                choice: None,
                error: "not loaded yet".to_owned(),
            },
            generation: 0,
            reload: false,
            messages: self.messages,
            status,
            shown: None,
            clock,
        };
        running.load_model();
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

    fn state(&self) -> ModelState {
        match self {
            Self::Loading { download, .. } => ModelState::Loading {
                // A finished download leaves the model loading.
                percent: download
                    .filter(|progress| progress.done < progress.total)
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
    hotkey: HotkeyWatch,
    /// The hotkey's name as people say it.
    hotkey_name: String,
    hotkey_paused: bool,
    model: Model,
    generation: u64,
    /// Load the model again even if the settings still choose it.
    reload: bool,
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
        if cancel && self.controller.is_recording() {
            self.controller.cancel();
        }
        self.controller.set_configuration(configuration::controller(after));
        self.controller.dependencies_mut().configure(after);
    }

    /// Starts loading the model the settings choose.
    fn load_model(&mut self) {
        self.generation += 1;
        self.model = match ModelChoice::from_settings(&self.settings) {
            Err(error) => Model::Failed {
                choice: None,
                error: format!("{error:#}"),
            },
            Ok(choice) => match Transcriber::load(choice.clone(), self.generation, self.messages.clone()) {
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
    /// first, so the two are never on the device together.
    fn load_model_if_changed(&mut self) {
        if matches!(self.model, Model::Loading { .. }) || !self.controller.is_idle() {
            return;
        }
        let reload = std::mem::take(&mut self.reload);
        let wanted = ModelChoice::from_settings(&self.settings).ok();
        if wanted.as_ref() == self.model.choice() && !reload {
            return;
        }
        self.controller.dependencies_mut().set_transcriber(None);
        let unloading = Model::Failed {
            choice: None,
            error: String::new(),
        };
        if let Model::Ready { transcriber, .. } = std::mem::replace(&mut self.model, unloading) {
            transcriber.finish();
        }
        self.load_model();
    }

    /// Tells the tray how things stand, when that has changed.
    fn report(&mut self) {
        let status = DictationStatus {
            phase: self.controller.phase(),
            model: self.model.state(),
            placement: match &self.model {
                Model::Ready { placement, .. } => Some(placement.clone()),
                _ => None,
            },
            hotkey: self.settings.dictation_enabled.then(|| self.hotkey_name.clone()),
            has_last_dictation: self.controller.last_text().is_some(),
            cleanup: self.controller.cleanup_level(),
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
