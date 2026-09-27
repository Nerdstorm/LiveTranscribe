//! The controller's view of this machine: the microphone, the speech model's thread, and the
//! Wayland session, which types the text and shows the panel. What happens is printed to
//! standard error as it happens; what was said never is.

use std::sync::mpsc::Sender;
use std::time::Instant;

use lt_capture::Recorder;
use lt_dictation::{Dependencies, Job, Notice, Phase, Recording};
use lt_dictation_ui::{PanelContent, PanelModel};
use lt_insertion::InsertionTarget;
use lt_wayland::WaylandSession;

use super::engine::Message;

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
    transcriber: Sender<(Job, Vec<f32>)>,
    session: WaylandSession,
    messages: Sender<Message>,
    panel: PanelModel,
    /// What the panel shows now.
    shown: Option<PanelContent>,
    clock: Clock,
}

impl Platform {
    pub(crate) fn new(
        recorder: Recorder,
        transcriber: Sender<(Job, Vec<f32>)>,
        session: WaylandSession,
        messages: Sender<Message>,
        panel: PanelModel,
        clock: Clock,
    ) -> Self {
        Self {
            recorder,
            transcriber,
            session,
            messages,
            panel,
            shown: None,
            clock,
        }
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
        self.session.copy(text);
    }

    fn refresh_panel(&mut self) {
        let content = self.panel.content();
        if content != self.shown {
            self.session.show_panel(content.clone());
            self.shown = content;
        }
    }
}

impl Dependencies for Platform {
    fn start_recording(&mut self) -> Result<(), String> {
        let input = self.recorder.start().map_err(|error| error.to_string())?;
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
        self.session.target()
    }

    fn transcribe(&mut self, job: Job, samples: Vec<f32>) {
        if self.transcriber.send((job, samples)).is_err() {
            let _ = self.messages.send(Message::Transcribed {
                job,
                result: Err("the speech model has stopped; restart livetranscribe".to_owned()),
            });
        }
    }

    fn prepare_insertion(&mut self) {
        self.session.prepare();
    }

    fn insert(&mut self, job: Job, text: String) {
        let messages = self.messages.clone();
        self.session.insert(text, move |result| {
            let result = result.map_err(|error| error.to_string());
            let _ = messages.send(Message::Inserted { job, result });
        });
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
