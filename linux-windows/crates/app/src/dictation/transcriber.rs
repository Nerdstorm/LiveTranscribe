//! The speech model, on a thread of its own: it loads, warms up, then transcribes jobs one at a
//! time and sends each result to the engine.

use std::path::PathBuf;
use std::sync::mpsc::{self, Sender};
use std::thread;
use std::time::Instant;

use anyhow::{Context, anyhow};
use lt_dictation::Job;
use lt_shared::audio_format::{SAMPLE_RATE, milliseconds_for_samples};
use lt_transcription::qwen3_asr::open_transcriber;

use super::engine::Message;
use crate::{ModelOptions, paths};

/// Loads the model and returns where to send jobs, once it is ready.
pub(crate) fn spawn(options: &ModelOptions, messages: Sender<Message>) -> anyhow::Result<Sender<(Job, Vec<f32>)>> {
    let folder: PathBuf = match &options.model {
        Some(folder) => folder.clone(),
        None => paths::default_model()?,
    };
    let device = options.device.clone();
    let (jobs, received) = mpsc::channel::<(Job, Vec<f32>)>();
    let (ready, answer) = mpsc::channel();
    eprintln!("Loading the speech model");
    thread::Builder::new()
        .name("transcriber".to_owned())
        .spawn(move || {
            let started = Instant::now();
            let mut transcriber = match open_transcriber(&folder, &device, paths::openvino_cache().as_deref()) {
                Ok(transcriber) => transcriber,
                Err(error) => {
                    let _ = ready.send(Err(
                        anyhow!(error).context(format!("couldn't load the speech model from {}", folder.display()))
                    ));
                    return;
                }
            };
            // The first run of a compiled model is slow; better now than on the first dictation.
            if let Err(error) = transcriber.transcribe(&vec![0.0; SAMPLE_RATE]) {
                tracing::warn!("Warming up the speech model failed: {error}");
            }
            let _ = ready.send(Ok((started.elapsed(), transcriber.model().placement())));
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
    let (loaded_in, placement) = answer
        .recv()
        .map_err(|_| anyhow!("the speech model's thread stopped while loading"))??;
    eprintln!("Speech model ready in {:.1} s: {placement}", loaded_in.as_secs_f32());
    Ok(jobs)
}
