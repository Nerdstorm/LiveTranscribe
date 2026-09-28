//! The speech model, on a thread of its own: it downloads the default model if it isn't there yet
//! (saying how far it has got, [`Message::ModelDownload`]), loads and warms up, says so to the
//! engine ([`Message::ModelLoaded`]), then transcribes jobs one at a time and sends each result
//! back. The thread ends, and the model is let go, when the engine drops the [`Jobs`] sender.

use std::sync::mpsc::{self, Sender};
use std::thread::{self, JoinHandle};
use std::time::Instant;

use anyhow::Context;
use lt_dictation::Job;
use lt_shared::audio_format::{SAMPLE_RATE, milliseconds_for_samples};
use lt_transcription::qwen3_asr::open_transcriber;

use super::configuration::ModelChoice;
use super::engine::Message;
use crate::{model_download, paths};

/// Where the engine sends what to transcribe.
pub(crate) type Jobs = Sender<(Job, Vec<f32>)>;

/// The model's thread, while it lives.
pub(crate) struct Transcriber {
    thread: JoinHandle<()>,
}

impl Transcriber {
    /// Starts loading `model` on a thread of its own. `Message::ModelLoaded` with `generation`
    /// says when it's ready, or why it couldn't load; the returned sender takes jobs from then.
    pub(crate) fn load(model: ModelChoice, generation: u64, messages: Sender<Message>) -> anyhow::Result<(Self, Jobs)> {
        let (jobs, received) = mpsc::channel::<(Job, Vec<f32>)>();
        let thread = thread::Builder::new()
            .name("transcriber".to_owned())
            .spawn(move || {
                if model.downloadable && !model_download::is_in_place(&model.folder) {
                    let downloaded = download(&model, generation, &messages);
                    if let Err(error) = downloaded {
                        let result = Err(format!("{error:#}"));
                        let _ = messages.send(Message::ModelLoaded { generation, result });
                        return;
                    }
                }
                eprintln!("Loading the speech model from {}", model.folder.display());
                let started = Instant::now();
                let mut transcriber =
                    match open_transcriber(&model.folder, &model.device, paths::openvino_cache().as_deref()) {
                        Ok(transcriber) => transcriber,
                        Err(error) => {
                            let error = format!(
                                "couldn't load the speech model from {}: {error}",
                                model.folder.display()
                            );
                            let _ = messages.send(Message::ModelLoaded {
                                generation,
                                result: Err(error),
                            });
                            return;
                        }
                    };
                // The first run of a compiled model is slow; better now than on the first dictation.
                if let Err(error) = transcriber.transcribe(&vec![0.0; SAMPLE_RATE]) {
                    tracing::warn!("Warming up the speech model failed: {error}");
                }
                let placement = transcriber.model().placement();
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
                    let result = transcriber
                        .transcribe(&samples)
                        .map(|transcription| transcription.text)
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
        Ok((Self { thread }, jobs))
    }

    /// Waits for the thread to end, once every [`Jobs`] sender has gone: after the job in hand,
    /// if any, and with the model let go, so another can take its place on the device.
    pub(crate) fn finish(self) {
        if self.thread.join().is_err() {
            tracing::error!("The speech model's thread panicked");
        }
    }
}

/// Downloads the default model into its folder, telling the engine how far it has got. It stops
/// when the engine has gone; what was downloaded stays for the next start.
fn download(model: &ModelChoice, generation: u64, messages: &Sender<Message>) -> anyhow::Result<()> {
    let default = &model_download::DEFAULT_MODEL;
    eprintln!(
        "Downloading the speech model, {} ({:.1} GB), from Hugging Face into {}",
        default.repository,
        default.size() as f64 / 1e9,
        model.folder.display()
    );
    let started = Instant::now();
    model_download::download(default, &model.folder, &mut |progress| {
        messages.send(Message::ModelDownload { generation, progress }).is_ok()
    })
    .with_context(|| format!("couldn't download the speech model into {}", model.folder.display()))?;
    eprintln!(
        "Downloaded the speech model in {:.0} s",
        started.elapsed().as_secs_f32()
    );
    Ok(())
}
