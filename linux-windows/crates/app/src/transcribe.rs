//! `livetranscribe transcribe`: each file's transcript on standard output, one line per file (or
//! with `--json`, one JSON object per file), and how long it took on standard error.

use std::path::PathBuf;
use std::time::Instant;

use anyhow::Context;
use lt_shared::audio_format::SAMPLE_RATE;
use lt_transcription::qwen3_asr::open_transcriber;

use crate::{ModelOptions, model_download, paths, wav};

pub fn run(options: &ModelOptions, files: &[PathBuf], json: bool) -> anyhow::Result<()> {
    let folder = match &options.model {
        Some(folder) => folder.clone(),
        None => paths::default_model()?,
    };
    if options.model.is_none() && !model_download::is_in_place(&folder) {
        download(&folder)?;
    }
    let started = Instant::now();
    let mut transcriber = open_transcriber(&folder, &options.device, paths::openvino_cache().as_deref())
        .with_context(|| format!("couldn't load the speech model from {}", folder.display()))?;
    eprintln!(
        "Loaded {} in {:.1} s: {}",
        folder.display(),
        started.elapsed().as_secs_f32(),
        transcriber.model().placement()
    );

    for file in files {
        let samples = wav::read_mono(file)?;
        let started = Instant::now();
        let transcription = transcriber
            .transcribe(&samples)
            .with_context(|| format!("couldn't transcribe {}", file.display()))?;
        let elapsed = started.elapsed().as_secs_f32();
        let seconds = samples.len() as f32 / SAMPLE_RATE as f32;
        eprintln!(
            "{}: {seconds:.1} s of audio in {elapsed:.2} s ({:.2} of real time), {}, {} tokens",
            file.display(),
            elapsed / seconds.max(f32::EPSILON),
            transcription.language.as_deref().unwrap_or("no language"),
            transcription.tokens
        );
        if json {
            let line = serde_json::json!({
                "file": file,
                "text": transcription.text,
                "language": transcription.language,
                "tokens": transcription.tokens,
                "seconds": seconds,
                "elapsed": elapsed,
            });
            println!("{line}");
        } else {
            println!("{}", transcription.text);
        }
    }
    Ok(())
}

/// Downloads the default model into `folder`, as dictation does the first time, saying on standard
/// error how far it has got.
fn download(folder: &std::path::Path) -> anyhow::Result<()> {
    let model = &model_download::DEFAULT_MODEL;
    eprintln!(
        "Downloading the speech model, {} ({:.1} GB), from Hugging Face into {}",
        model.repository,
        model.size() as f64 / 1e9,
        folder.display()
    );
    let mut shown = None;
    model_download::download(model, folder, &mut |progress| {
        let percent = progress.percent();
        if shown.is_none_or(|shown| percent >= shown + 5) {
            eprintln!("  {percent}%");
            shown = Some(percent);
        }
        true
    })
    .with_context(|| format!("couldn't download the speech model into {}", folder.display()))
}
