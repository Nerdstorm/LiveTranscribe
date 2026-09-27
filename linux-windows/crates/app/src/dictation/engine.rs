//! The dictation engine, on a thread of its own. It loads the speech model, then feeds the
//! controller what happens (the hotkey, the menu, the workers' results) in the order it happens,
//! with times from one clock, and runs the gesture's and the panel's timers.
//! After each, the tray hears how things stand, when that has changed.

use std::sync::mpsc::{Receiver, RecvTimeoutError, Sender};
use std::thread;
use std::time::Duration;

use lt_capture::Recorder;
use lt_dictation::{ControllerConfiguration, DictationController, Job, Phase};
use lt_dictation_ui::{MenuBarStatus, ModelState, PanelModel};
use lt_hotkey::HotkeyEvent;
use lt_insertion::Inserted;
use lt_shared::CleanupLevel;
use lt_wayland::WaylandSession;

use super::platform::{Clock, Platform};
use super::transcriber;
use super::tray::{StatusSink, TrayStatus};
use crate::ModelOptions;

pub(crate) enum Message {
    Hotkey(HotkeyEvent),
    Menu(MenuCommand),
    Transcribed { job: Job, result: Result<String, String> },
    Inserted { job: Job, result: Result<Inserted, String> },
}

/// What the tray's menu asks for.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum MenuCommand {
    ToggleDictation,
    CancelDictation,
    CopyLastDictation,
    SetCleanup(CleanupLevel),
}

pub(crate) struct Engine {
    pub(crate) configuration: ControllerConfiguration,
    pub(crate) model: ModelOptions,
    /// The hotkey's name as people say it.
    pub(crate) hotkey: String,
    pub(crate) notice_ms: u64,
    pub(crate) recorder: Recorder,
    pub(crate) session: WaylandSession,
    pub(crate) messages: Sender<Message>,
    pub(crate) received: Receiver<Message>,
}

impl Engine {
    /// Runs the engine on a thread of its own, telling the tray how things stand through
    /// `status`.
    pub(crate) fn start(self, status: StatusSink) {
        let spawned = thread::Builder::new()
            .name("dictation".to_owned())
            .spawn(move || self.run(status));
        if let Err(error) = spawned {
            eprintln!("livetranscribe: couldn't start dictation: {error}");
        }
    }

    fn run(mut self, status: StatusSink) {
        let mut reporter = StatusReporter {
            sink: status,
            hotkey: self.hotkey.clone(),
            shown: None,
        };
        let level = self.configuration.text.level;
        reporter.report(Phase::Idle, &ModelState::Loading, false, level);
        let transcriber = match transcriber::spawn(&self.model, self.messages.clone()) {
            Ok(transcriber) => transcriber,
            Err(error) => {
                eprintln!("livetranscribe: {error:#}");
                reporter.report(Phase::Idle, &ModelState::Failed(format!("{error:#}")), false, level);
                // The tray stays, saying what went wrong, until it is quit.
                for _ in self.received.iter() {}
                return;
            }
        };
        // Keys pressed while the model loaded are not a dictation; a cleanup level chosen then
        // counts.
        while let Ok(message) = self.received.try_recv() {
            if let Message::Menu(MenuCommand::SetCleanup(level)) = message {
                self.configuration.text.level = level;
            }
        }
        eprintln!(
            "Ready. Hold {} and speak; release to type the text.{} Esc cancels. Quit from the tray, \
             or with Ctrl+C here.",
            self.hotkey,
            if self.configuration.gesture.hands_free_enabled {
                " Tap it twice to keep recording hands-free until you press it again."
            } else {
                ""
            }
        );
        let clock = Clock::start();
        let platform = Platform::new(
            self.recorder,
            transcriber,
            self.session,
            self.messages,
            PanelModel::new(self.notice_ms),
            clock,
        );
        let mut controller = DictationController::new(self.configuration, platform);
        dictate(&mut controller, &self.received, &mut reporter, clock);
    }
}

/// Feeds the controller until every sender has gone.
fn dictate(
    controller: &mut DictationController<Platform>,
    messages: &Receiver<Message>,
    reporter: &mut StatusReporter,
    clock: Clock,
) {
    loop {
        reporter.report(
            controller.phase(),
            &ModelState::Ready,
            controller.last_text().is_some(),
            controller.cleanup_level(),
        );
        let deadline = [controller.next_timer(), controller.dependencies().panel_deadline()]
            .into_iter()
            .flatten()
            .min();
        let message = match deadline {
            Some(deadline) => {
                let now = clock.now_ms();
                if deadline <= now {
                    if controller.next_timer().is_some_and(|timer| timer <= now) {
                        controller.timer_fired(now);
                    }
                    controller.dependencies_mut().advance_panel(now);
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
        let now = clock.now_ms();
        match message {
            Message::Hotkey(event) => controller.hotkey(event, now),
            Message::Menu(MenuCommand::ToggleDictation) => controller.toggle_dictation(now),
            Message::Menu(MenuCommand::CancelDictation) => controller.cancel(),
            Message::Menu(MenuCommand::CopyLastDictation) => {
                if let Some(text) = controller.last_text().map(str::to_owned) {
                    eprintln!("Copied the last dictation ({} characters)", text.chars().count());
                    controller.dependencies().copy(text);
                }
            }
            Message::Menu(MenuCommand::SetCleanup(level)) => {
                eprintln!("Cleanup: {}", level.display_name());
                controller.set_cleanup_level(level);
            }
            Message::Transcribed { job, result } => controller.transcribed(job, result),
            Message::Inserted { job, result } => controller.inserted(job, result, now),
        }
    }
}

/// Tells the tray how things stand, when that has changed.
struct StatusReporter {
    sink: StatusSink,
    hotkey: String,
    shown: Option<TrayStatus>,
}

impl StatusReporter {
    fn report(&mut self, phase: Phase, model: &ModelState, has_last_dictation: bool, cleanup: CleanupLevel) {
        let status = TrayStatus {
            menu: MenuBarStatus::new(phase, model, &self.hotkey, has_last_dictation),
            cleanup,
        };
        if self.shown.as_ref() != Some(&status) {
            (self.sink)(&status);
            self.shown = Some(status);
        }
    }
}
