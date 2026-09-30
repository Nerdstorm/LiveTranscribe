//! Cleanup's language model, on a thread of its own: it downloads the model the first time (saying
//! how far it has got in [`Message::CleanupDownload`]) and checks it, opens it on the CPU with the
//! Mac app's adapters, warms up, says so ([`Message::CleanupLoaded`]), then cleans jobs one at a
//! time as the Mac app does (lt-cleanup's executor) and sends each result back
//! ([`Message::Cleaned`]). The thread ends, and the model is let go, when the engine drops the
//! [`CleanupJobs`] sender. [`CleanupModelSlot`] is how the engine keeps it: loaded while the settings
//! have it on, and let go when they don't.

use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Sender};
use std::thread::{self, JoinHandle};
use std::time::Instant;

use anyhow::Context;
use lt_cleanup::{
    Adapter, CancelFlag, CleanupExecutor, CleanupModel, CleanupOptions, Deadline, OutputGuard, PromptBuilder,
    SystemClock, WARM_UP_TIMEOUT_SECONDS, warm_up_request,
};
use lt_dictation::Job;
use lt_dictation_ui::ModelState;
use lt_language_model::pinned_model::{self, PrepareError};
use lt_language_model::{CLEANUP_MODEL, LanguageModel};

use super::cleanup_model::OpenVinoCleanup;
use super::engine::{CleanupModelStatus, Message};
use crate::paths;
use crate::speech_models::{Progress, Stage};

/// Earlier segments the model sees before the text, as the Mac app's default. Dictation sends
/// none, so this only matters to the executor's prompt budget.
const CONTEXT_LIMIT: usize = 3;

/// Where the engine sends what to clean up.
pub(crate) type CleanupJobs = Sender<CleanupJob>;

/// A transcript to clean up.
pub(crate) struct CleanupJob {
    pub(crate) job: Job,
    pub(crate) text: String,
    pub(crate) options: CleanupOptions,
    /// How long it may take: the Advanced setting, which the executor stretches to Deep's minimum
    /// at Deep.
    pub(crate) timeout_seconds: f64,
    /// Set when the dictation is cancelled: the model stops, and the result is dropped.
    pub(crate) cancel: CancelFlag,
}

/// The model's thread, while it lives.
pub(crate) struct Cleaner {
    thread: JoinHandle<()>,
    /// Set when the engine no longer wants the model, while it still downloads.
    abandon: Arc<AtomicBool>,
}

impl Cleaner {
    /// Starts preparing the cleanup model on a thread of its own. `Message::CleanupLoaded` with
    /// `generation` says when it's ready, or why it couldn't load; the returned sender takes jobs
    /// from then.
    pub(crate) fn load(generation: u64, messages: Sender<Message>) -> anyhow::Result<(Self, CleanupJobs)> {
        let models = paths::models_folder()?;
        let (jobs, received) = mpsc::channel::<CleanupJob>();
        let abandon = Arc::new(AtomicBool::new(false));
        let abandoned = Arc::clone(&abandon);
        let thread = thread::Builder::new()
            .name("cleanup".to_owned())
            .spawn(move || {
                let started = Instant::now();
                let mut model = match open(&models, generation, &messages, &abandoned) {
                    Ok(Some(model)) => model,
                    // The engine no longer wants it.
                    Ok(None) => return,
                    Err(error) => {
                        let result = Err(format!("{error:#}"));
                        let _ = messages.send(Message::CleanupLoaded { generation, result });
                        return;
                    }
                };
                // As on the Mac, the prompts ask for self-corrections to be resolved only when the
                // adapter that learned to is there.
                let prompts = PromptBuilder::new(model.adapters().contains(&Adapter::Medium));
                // The first run of a compiled model is slow; better now than on the first dictation.
                let never = CancelFlag::new();
                let deadline = Deadline::new(&SystemClock, WARM_UP_TIMEOUT_SECONDS, &never);
                if let Err(error) = model.generate(&warm_up_request(&prompts), &deadline) {
                    tracing::warn!("Warming up the cleanup model failed: {error}");
                }
                let placement = placement(&model);
                eprintln!(
                    "Cleanup model ready in {:.1} s: {placement}",
                    started.elapsed().as_secs_f32()
                );
                let loaded = Message::CleanupLoaded {
                    generation,
                    result: Ok(placement),
                };
                if messages.send(loaded).is_err() {
                    return;
                }
                for CleanupJob {
                    job,
                    text,
                    options,
                    timeout_seconds,
                    cancel,
                } in received
                {
                    let executor =
                        CleanupExecutor::new(CONTEXT_LIMIT, timeout_seconds, OutputGuard::default(), prompts.clone());
                    let cleaned = executor.run(&text, &[], &options, &mut model, &cancel);
                    tracing::info!(
                        "Cleaned {} characters at {} in {} ms{}",
                        text.chars().count(),
                        options.level.display_name(),
                        cleaned.latency_ms,
                        if cleaned.fell_back() { ", falling back" } else { "" }
                    );
                    if messages.send(Message::Cleaned { job, cleaned }).is_err() {
                        return;
                    }
                }
            })
            .context("couldn't start the cleanup model's thread")?;
        Ok((Self { thread, abandon }, jobs))
    }

    /// Stops waiting for the model's download, which carries on where it stopped next time; a
    /// model already loading loads, and is let go once [`Self::finish`] has it.
    pub(crate) fn abandon(&self) {
        self.abandon.store(true, Ordering::Relaxed);
    }

    /// Waits for the thread to end, once every [`CleanupJobs`] sender has gone: after the job in
    /// hand, if any, and with the model let go.
    pub(crate) fn finish(self) {
        if self.thread.join().is_err() {
            tracing::error!("The cleanup model's thread panicked");
        }
    }
}

/// Cleanup's language model as the engine keeps it: off, loading, loaded, or not.
#[derive(Default)]
pub(crate) struct CleanupModelSlot {
    state: State,
    /// The latest load's, to tell its messages from an earlier one's.
    generation: u64,
}

#[derive(Default)]
enum State {
    #[default]
    Off,
    Loading {
        generation: u64,
        /// How far downloading the model has got, while it downloads.
        download: Option<Progress>,
        cleaner: Cleaner,
        jobs: CleanupJobs,
    },
    Ready {
        cleaner: Cleaner,
        /// Where it runs, and with which adapters.
        placement: String,
    },
    Failed {
        error: String,
    },
}

impl CleanupModelSlot {
    /// How it stands, for the tray and Settings; `None` while it's off.
    pub(crate) fn status(&self) -> Option<CleanupModelStatus> {
        let (state, download, placement) = match &self.state {
            State::Off => return None,
            State::Loading { download, .. } => {
                let download = download.filter(|progress| progress.done < progress.total);
                let percent = download
                    .filter(|progress| progress.stage == Stage::Downloading)
                    .map(Progress::percent);
                (ModelState::Loading { percent }, download, None)
            }
            State::Ready { placement, .. } => (ModelState::Ready, None, Some(placement.clone())),
            State::Failed { error } => (ModelState::Failed(error.clone()), None, None),
        };
        Some(CleanupModelStatus {
            state,
            download,
            placement,
        })
    }

    /// Starts loading the model when it's `wanted` and off, or lets it go when it isn't wanted:
    /// after `release` has dropped the sender the platform was given, since the model's thread
    /// ends only once every sender has gone. One that failed stays failed until
    /// [`Self::try_again`].
    pub(crate) fn want(&mut self, wanted: bool, messages: &Sender<Message>, release: impl FnOnce()) {
        match (&self.state, wanted) {
            (State::Off, true) => self.load(messages),
            (State::Failed { .. }, false) => self.state = State::Off,
            (State::Loading { .. } | State::Ready { .. }, false) => {
                release();
                match std::mem::take(&mut self.state) {
                    State::Ready { cleaner, .. } => cleaner.finish(),
                    State::Loading { cleaner, jobs, .. } => {
                        cleaner.abandon();
                        drop(jobs);
                        cleaner.finish();
                    }
                    State::Off | State::Failed { .. } => {}
                }
                eprintln!("Let the cleanup model go");
            }
            _ => {}
        }
    }

    /// Settings asks for the model again after it failed; the engine loads it next.
    pub(crate) fn try_again(&mut self) {
        if matches!(self.state, State::Failed { .. }) {
            self.state = State::Off;
        }
    }

    /// How far load `generation`'s download has got.
    pub(crate) fn downloading(&mut self, generation: u64, progress: Progress) {
        if let State::Loading {
            generation: loading,
            download,
            ..
        } = &mut self.state
            && *loading == generation
        {
            *download = Some(progress);
        }
    }

    /// Load `generation` has finished: where the model runs, or why it couldn't load. Returns the
    /// sender that takes jobs from now on, for the platform, if it loaded and is still the one
    /// wanted.
    pub(crate) fn loaded(&mut self, generation: u64, result: Result<String, String>) -> Option<CleanupJobs> {
        if !matches!(&self.state, State::Loading { generation: loading, .. } if *loading == generation) {
            return None;
        }
        let State::Loading { cleaner, jobs, .. } = std::mem::take(&mut self.state) else {
            return None;
        };
        match result {
            Ok(placement) => {
                self.state = State::Ready { cleaner, placement };
                Some(jobs)
            }
            Err(error) => {
                eprintln!("livetranscribe: {error}");
                drop(jobs);
                cleaner.finish();
                self.state = State::Failed { error };
                None
            }
        }
    }

    fn load(&mut self, messages: &Sender<Message>) {
        self.generation += 1;
        self.state = match Cleaner::load(self.generation, messages.clone()) {
            Ok((cleaner, jobs)) => State::Loading {
                generation: self.generation,
                download: None,
                cleaner,
                jobs,
            },
            Err(error) => {
                eprintln!("livetranscribe: {error:#}");
                State::Failed {
                    error: format!("{error:#}"),
                }
            }
        };
    }
}

/// Downloads the cleanup model into the models folder if it isn't there yet, checks it and opens
/// it; `None` if the engine stopped wanting it first.
fn open(
    models: &Path,
    generation: u64,
    messages: &Sender<Message>,
    abandon: &AtomicBool,
) -> anyhow::Result<Option<OpenVinoCleanup>> {
    let prepared = pinned_model::prepare(&CLEANUP_MODEL, models, &mut |progress| {
        !abandon.load(Ordering::Relaxed)
            && messages
                .send(Message::CleanupDownload {
                    generation,
                    progress: Progress {
                        stage: match progress.stage {
                            pinned_model::Stage::Checking => Stage::Checking,
                            pinned_model::Stage::Downloading => Stage::Downloading,
                        },
                        done: progress.done,
                        total: progress.total,
                    },
                })
                .is_ok()
    });
    let folder = match prepared {
        Ok(folder) => folder,
        Err(PrepareError::Stopped) => return Ok(None),
        Err(error) => return Err(anyhow::Error::new(error).context("couldn't download the cleanup model")),
    };
    if abandon.load(Ordering::Relaxed) {
        return Ok(None);
    }
    eprintln!("Loading the cleanup model from {}", folder.display());
    let options = lt_language_model::Options {
        device: "CPU".to_owned(),
        cache: paths::openvino_cache(),
        properties: Vec::new(),
    };
    let model = LanguageModel::open(&folder, &options).context("couldn't load the cleanup model")?;
    Ok(Some(OpenVinoCleanup::new(model)))
}

/// Where the model runs, and with which of the Mac app's adapters.
fn placement(model: &OpenVinoCleanup) -> String {
    let adapters = match (
        model.adapters().contains(&Adapter::Medium),
        model.adapters().contains(&Adapter::Deep),
    ) {
        (true, true) => "with the self-correction and Deep adapters",
        (true, false) => "with the self-correction adapter",
        (false, true) => "with Deep's adapter",
        (false, false) => "without its adapters",
    };
    format!("{}, {adapters}", model.device())
}
