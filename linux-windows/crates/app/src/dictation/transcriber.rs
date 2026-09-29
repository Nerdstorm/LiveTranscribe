//! The speech model, on a thread of its own: it waits for a catalog model's download if it isn't
//! here yet (the library's, which Settings › Models shows too, saying how far it has got in
//! [`Message::ModelDownload`]), checks it, loads and warms up, says so to the engine
//! ([`Message::ModelLoaded`]), then transcribes jobs one at a time and sends each result back. The
//! thread ends, and the model is let go, when the engine drops the [`Jobs`] sender.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Sender};
use std::thread::{self, JoinHandle};
use std::time::Instant;

use anyhow::Context;
use lt_dictation::Job;
use lt_shared::audio_format::{SAMPLE_RATE, milliseconds_for_samples};
use lt_transcription::speech_to_text::SpeechToText;

use super::configuration::ModelChoice;
use super::engine::Message;
use crate::paths;
use crate::speech_models::{ChosenModel, EnsureError, SpeechModelLibrary};

/// Where the engine sends what to transcribe.
pub(crate) type Jobs = Sender<(Job, Vec<f32>)>;

/// The model's thread, while it lives.
pub(crate) struct Transcriber {
    thread: JoinHandle<()>,
    /// Set when the engine no longer wants the model, while it still waits for its download.
    abandon: Arc<AtomicBool>,
}

impl Transcriber {
    /// Starts loading `model` on a thread of its own. `Message::ModelLoaded` with `generation`
    /// says when it's ready, or why it couldn't load; the returned sender takes jobs from then.
    pub(crate) fn load(
        model: ModelChoice,
        generation: u64,
        messages: Sender<Message>,
        library: Arc<SpeechModelLibrary>,
    ) -> anyhow::Result<(Self, Jobs)> {
        let (jobs, received) = mpsc::channel::<(Job, Vec<f32>)>();
        let abandon = Arc::new(AtomicBool::new(false));
        let abandoned = Arc::clone(&abandon);
        let thread = thread::Builder::new()
            .name("transcriber".to_owned())
            .spawn(move || {
                let started = Instant::now();
                let mut speech = match open(&model, generation, &messages, &library, &abandoned) {
                    Ok(Some(speech)) => speech,
                    // The engine has moved on to another model.
                    Ok(None) => return,
                    Err(error) => {
                        let result = Err(format!("{error:#}"));
                        let _ = messages.send(Message::ModelLoaded { generation, result });
                        return;
                    }
                };
                // The first run of a compiled model is slow; better now than on the first dictation.
                if let Err(error) = speech.transcribe(&vec![0.0; SAMPLE_RATE]) {
                    tracing::warn!("Warming up the speech model failed: {error}");
                }
                let placement = speech.placement();
                eprintln!(
                    "Speech model ready in {:.1} s: {placement}",
                    started.elapsed().as_secs_f32()
                );
                let loaded = Message::ModelLoaded {
                    generation,
                    result: Ok(placement),
                };
                if messages.send(loaded).is_err() {
                    return;
                }
                for (job, samples) in received {
                    let started = Instant::now();
                    let result = speech
                        .transcribe(&samples)
                        .map(|transcript| transcript.text)
                        .map_err(|error| error.to_string());
                    tracing::info!(
                        "Transcribed {} ms of audio in {} ms",
                        milliseconds_for_samples(samples.len()),
                        started.elapsed().as_millis()
                    );
                    if messages.send(Message::Transcribed { job, result }).is_err() {
                        return;
                    }
                }
            })
            .context("couldn't start the transcriber")?;
        Ok((Self { thread, abandon }, jobs))
    }

    /// Stops waiting for the model's download, which carries on in Settings › Models; a model
    /// already loading loads, and is let go once [`Self::finish`] has it.
    pub(crate) fn abandon(&self) {
        self.abandon.store(true, Ordering::Relaxed);
    }

    /// Waits for the thread to end, once every [`Jobs`] sender has gone: after the job in hand,
    /// if any, and with the model let go, so another can take its place on the device.
    pub(crate) fn finish(self) {
        if self.thread.join().is_err() {
            tracing::error!("The speech model's thread panicked");
        }
    }
}

/// Opens the model chosen, once a catalog model is downloaded and checked; `None` if the engine
/// stopped wanting it first.
fn open(
    model: &ModelChoice,
    generation: u64,
    messages: &Sender<Message>,
    library: &Arc<SpeechModelLibrary>,
    abandon: &AtomicBool,
) -> anyhow::Result<Option<SpeechToText>> {
    let cache = paths::openvino_cache();
    let opened = match &model.model {
        ChosenModel::Catalog(catalog_model) => {
            let waited = library.ensure(catalog_model, &mut |progress| {
                !abandon.load(Ordering::Relaxed)
                    && messages.send(Message::ModelDownload { generation, progress }).is_ok()
            });
            let verified = match waited {
                Ok(verified) => verified,
                Err(EnsureError::Abandoned) => return Ok(None),
                Err(error) => {
                    return Err(anyhow::Error::new(error).context(format!("couldn't download {}", catalog_model.name)));
                }
            };
            if abandon.load(Ordering::Relaxed) {
                return Ok(None);
            }
            eprintln!(
                "Loading the speech model {} from {}",
                catalog_model.name,
                verified.folder().display()
            );
            SpeechToText::open(&verified, &model.device, cache.as_deref())
        }
        ChosenModel::Converted(folder) => {
            eprintln!("Loading the speech model from {}", folder.display());
            SpeechToText::open_converted(folder, &model.device, cache.as_deref())
        }
    };
    opened
        .map(Some)
        .with_context(|| format!("couldn't load the speech model {}", model.model.name()))
}
