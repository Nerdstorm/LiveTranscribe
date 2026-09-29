//! The controller's view of this machine: the microphone, the speech model's thread, and the
//! desktop, which types the text and shows the panel. What happens is printed to standard error as
//! it happens; what was said never is.

use std::sync::mpsc::Sender;
use std::time::Instant;

use lt_capture::Recorder;
use lt_dictation::{Dependencies, Job, Notice, Phase, Recording};
use lt_dictation_ui::{PanelContent, PanelModel};
use lt_insertion::InsertionTarget;

use super::configuration;
use super::desktop::Desktop;
use super::engine::Message;
use super::transcriber::{Clip, Jobs};
use crate::settings::Settings;

/// Milliseconds since the engine started: the one clock the controller and the panel share.
#[derive(Clone, Copy, Debug)]
pub(crate) struct Clock(Instant);

impl Clock {
    pub(crate) fn start() -> Self {
        Self(Instant::now())
    }

    pub(crate) fn now_ms(self) -> u64 {
        u64::try_from(self.0.elapsed().as_millis()).unwrap_or(u64::MAX)
    }
}

pub(crate) struct Platform {
    recorder: Recorder,
    /// The speech model's jobs, while it is loaded.
    transcriber: Option<Jobs>,
    /// The Language setting each recording goes to the model with.
    language: Option<String>,
    desktop: Box<dyn Desktop>,
    messages: Sender<Message>,
    panel: PanelModel,
    /// What the panel shows now.
    shown: Option<PanelContent>,
    clock: Clock,
}

impl Platform {
    pub(crate) fn new(
        recorder: Recorder,
        desktop: Box<dyn Desktop>,
        messages: Sender<Message>,
        panel: PanelModel,
        language: Option<String>,
        clock: Clock,
    ) -> Self {
        Self {
            recorder,
            transcriber: None,
            language,
            desktop,
            messages,
            panel,
            shown: None,
            clock,
        }
    }

    /// Sends jobs to `transcriber` from now on; `None` while no model is loaded.
    pub(crate) fn set_transcriber(&mut self, transcriber: Option<Jobs>) {
        self.transcriber = transcriber;
    }

    /// Records, transcribes, shows messages and pastes with `settings` from the next time each
    /// happens.
    pub(crate) fn configure(&mut self, settings: &Settings) {
        self.recorder.configure(configuration::recorder(settings));
        self.language = configuration::language(settings);
        self.panel.set_notice_ms(configuration::notice_ms(settings));
        self.desktop.set_insertion(configuration::insertion(settings));
    }

    /// When the panel's message runs out: call [`Self::advance_panel`] then.
    pub(crate) fn panel_deadline(&self) -> Option<u64> {
        self.panel.next_deadline()
    }

    pub(crate) fn advance_panel(&mut self, now_ms: u64) {
        self.panel.advance(now_ms);
        self.refresh_panel();
    }

    /// Puts `text` on the clipboard, for *Copy Last Dictation*.
    pub(crate) fn copy(&self, text: String) {
        self.desktop.copy(text);
    }

    fn refresh_panel(&mut self) {
        let content = self.panel.content();
        if content != self.shown {
            self.desktop.show_panel(content.clone());
            self.shown = content;
        }
    }
}

impl Dependencies for Platform {
    fn start_recording(&mut self) -> Result<(), String> {
        let input = self.recorder.start().map_err(|error| error.to_string())?;
        if input.chosen_missing {
            eprintln!(
                "⚠ The microphone chosen in Settings isn't connected; recording from {}",
                input.device
            );
        }
        tracing::info!(
            "Recording from {} at {} Hz, {} channels",
            input.device,
            input.sample_rate,
            input.channels
        );
        Ok(())
    }

    fn stop_recording(&mut self) -> Recording {
        let recording = self.recorder.stop();
        Recording {
            samples: recording.samples,
            truncated: recording.truncated,
            failure: recording.failure,
        }
    }

    fn cancel_recording(&mut self) {
        self.recorder.cancel();
    }

    fn target(&mut self) -> InsertionTarget {
        self.desktop.target()
    }

    fn transcribe(&mut self, job: Job, samples: Vec<f32>) {
        let sent = match &self.transcriber {
            Some(transcriber) => {
                let language = self.language.clone();
                transcriber.send(Clip { job, samples, language }).is_ok()
            }
            None => false,
        };
        if !sent {
            let _ = self.messages.send(Message::Transcribed {
                job,
                result: Err("the speech model isn't loaded".to_owned()),
            });
        }
    }

    fn prepare_insertion(&mut self) {
        self.desktop.prepare();
    }

    fn insert(&mut self, job: Job, text: String) {
        let messages = self.messages.clone();
        self.desktop.insert(
            text,
            Box::new(move |result| {
                let _ = messages.send(Message::Inserted { job, result });
            }),
        );
    }

    fn phase_changed(&mut self, phase: Phase) {
        match phase {
            Phase::Recording { hands_free: false } => eprintln!("● Listening"),
            Phase::Recording { hands_free: true } => eprintln!("● Listening, hands-free"),
            Phase::Processing { audio_ms } => {
                eprintln!("  Transcribing {:.1} s of speech", audio_ms as f32 / 1_000.0);
            }
            Phase::Idle => {}
        }
        self.panel.phase_changed(phase);
        self.refresh_panel();
    }

    fn end_dictation(&mut self, notices: Vec<Notice>) {
        notices.iter().for_each(print);
        self.panel.end_dictation(notices, self.clock.now_ms());
        self.refresh_panel();
    }

    fn show_progress(&mut self, notice: Notice) {
        print(&notice);
        self.panel.show_progress(notice, self.clock.now_ms());
        self.refresh_panel();
    }
}

fn print(notice: &Notice) {
    if notice.is_problem() {
        eprintln!("⚠ {}", notice.message());
    } else {
        eprintln!("  {}", notice.message());
    }
}
