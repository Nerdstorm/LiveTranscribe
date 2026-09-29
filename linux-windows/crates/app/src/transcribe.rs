//! `livetranscribe transcribe`: each file's transcript on standard output, one line per file (or
//! with `--json`, one JSON object per file), and how long it took on standard error. And
//! `livetranscribe models`, the speech models it can download.

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Instant;

use anyhow::Context;
use lt_shared::audio_format::SAMPLE_RATE;
use lt_transcription::catalog::SpeechModelCatalog;
use lt_transcription::qwen3_asr::DeviceChoice;
use lt_transcription::speech_to_text::SpeechToText;

use crate::speech_models::{
    ChosenModel, DEFAULT_MODEL, DownloadState, Progress, SpeechModelDownloads, SpeechModelLibrary, Stage,
};
use crate::{ModelOptions, paths, wav};

pub fn run(options: &ModelOptions, files: &[PathBuf], json: bool) -> anyhow::Result<()> {
    let library = library()?;
    let chosen = chosen(options.model.as_deref(), &library)?;
    if !chosen.runs_on_openvino() && options.device != DeviceChoice::Auto {
        eprintln!(
            "⚠ {} runs on the CPU: --device is for the Qwen3-ASR models",
            chosen.name()
        );
    }
    let language = told_language(&chosen, options.language.as_deref())?;
    let cache = paths::openvino_cache();
    let started;
    let opened = match &chosen {
        ChosenModel::Catalog(model) => {
            let mut shown = None;
            let verified = library
                .ensure(model, &mut |progress| {
                    show(progress, &mut shown);
                    true
                })
                .with_context(|| format!("couldn't download {}", model.name))?;
            started = Instant::now();
            SpeechToText::open(&verified, &options.device, cache.as_deref())
        }
        ChosenModel::Converted(folder) => {
            started = Instant::now();
            SpeechToText::open_converted(folder, &options.device, cache.as_deref())
        }
    };
    let mut speech = opened.with_context(|| format!("couldn't load {}", chosen.name()))?;
    eprintln!(
        "Loaded {} in {:.1} s: {}",
        chosen.name(),
        started.elapsed().as_secs_f32(),
        speech.placement()
    );

    for file in files {
        let samples = wav::read_mono(file)?;
        let started = Instant::now();
        let transcript = speech
            .transcribe(&samples, language)
            .with_context(|| format!("couldn't transcribe {}", file.display()))?;
        let elapsed = started.elapsed().as_secs_f32();
        let seconds = samples.len() as f32 / SAMPLE_RATE as f32;
        eprintln!(
            "{}: {seconds:.1} s of audio in {elapsed:.2} s ({:.2} of real time), {}, {} tokens",
            file.display(),
            elapsed / seconds.max(f32::EPSILON),
            transcript.language.as_deref().unwrap_or("no language"),
            transcript.tokens
        );
        if json {
            let line = serde_json::json!({
                "file": file,
                "text": transcript.text,
                "language": transcript.language,
                "tokens": transcript.tokens,
                "seconds": seconds,
                "elapsed": elapsed,
            });
            println!("{line}");
        } else {
            println!("{}", transcript.text);
        }
    }
    Ok(())
}

/// The catalog's models, in the models folder.
fn library() -> anyhow::Result<Arc<SpeechModelLibrary>> {
    Ok(SpeechModelLibrary::new(
        SpeechModelCatalog::bundled(),
        SpeechModelDownloads::new(paths::models_folder()?),
    ))
}

/// The model `--model` names: a catalog model's id, or a folder, given from where the command
/// runs or in the models folder.
fn chosen(option: Option<&str>, library: &SpeechModelLibrary) -> anyhow::Result<ChosenModel> {
    let setting = option.unwrap_or(DEFAULT_MODEL);
    let catalog = library.catalog();
    if catalog.model(setting).is_none() && Path::new(setting).is_dir() {
        let folder = std::path::absolute(setting).with_context(|| format!("{setting} isn't a path"))?;
        return Ok(ChosenModel::Converted(folder));
    }
    let chosen = ChosenModel::named(setting, catalog, library.downloads().folder());
    if let ChosenModel::Converted(folder) = &chosen
        && !folder.is_dir()
    {
        anyhow::bail!(
            "{setting} is neither a model `livetranscribe models` lists nor a folder ({} isn't one)",
            folder.display()
        );
    }
    Ok(chosen)
}

/// The code of the language `--language` names, for the model chosen: `None` without the option,
/// and for a model that finds the language itself, which is said on standard error. A language
/// the model can't be told is refused.
fn told_language<'a>(chosen: &'a ChosenModel, option: Option<&str>) -> anyhow::Result<Option<&'a str>> {
    let Some(text) = option else { return Ok(None) };
    let choices = match chosen {
        ChosenModel::Catalog(model) => model.language_choices.as_slice(),
        ChosenModel::Converted(_) => &[],
    };
    if choices.is_empty() {
        eprintln!(
            "⚠ {} finds the language itself: --language is for Cohere Transcribe",
            chosen.name()
        );
        return Ok(None);
    }
    match choices.iter().find(|choice| choice.is_named(text)) {
        Some(choice) => Ok(Some(choice.code.as_str())),
        None => {
            let known: Vec<String> = choices
                .iter()
                .map(|choice| format!("{} ({})", choice.code, choice.name))
                .collect();
            anyhow::bail!(
                "{} can't be told to write {text}: it writes {}",
                chosen.name(),
                known.join(", ")
            )
        }
    }
}

/// Says on standard error how far a download has got, every 5%, and when each stage finishes.
fn show(progress: Progress, shown: &mut Option<(Stage, u8)>) {
    if !is_due(progress, *shown) {
        return;
    }
    let stage = match progress.stage {
        Stage::Downloading => "Downloading",
        Stage::Unpacking => "Unpacking",
        Stage::Checking => "Checking",
    };
    let percent = progress.percent();
    eprintln!("  {stage}: {percent}%");
    *shown = Some((progress.stage, percent));
}

/// Whether `progress` is worth saying, after what was said last: a new stage, 5% more of this
/// one, or its end.
fn is_due(progress: Progress, shown: Option<(Stage, u8)>) -> bool {
    let percent = progress.percent();
    match shown {
        Some((stage, last)) => stage != progress.stage || percent >= last + 5 || (percent == 100 && last < 100),
        None => true,
    }
}

/// `livetranscribe models`: each model this app can download, its size, and whether it's here.
pub fn list_models() -> anyhow::Result<()> {
    let library = library()?;
    for model in library.catalog().models() {
        let mut notes = Vec::new();
        if model.id == DEFAULT_MODEL {
            notes.push("default");
        }
        if library.state(model) == DownloadState::Downloaded {
            notes.push("downloaded");
        }
        println!(
            "{:<24} {:<24} {:>5.1} GB  {}{}",
            model.id,
            model.name,
            model.download_bytes() as f64 / 1e9,
            model.languages,
            if notes.is_empty() {
                String::new()
            } else {
                format!(" ({})", notes.join(", "))
            }
        );
    }
    eprintln!(
        "Models are downloaded into {} the first time they're used: pass --model and a model's id.",
        library.downloads().folder().display()
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn at(stage: Stage, done: u64) -> Progress {
        Progress {
            stage,
            done,
            total: 100,
        }
    }

    #[test]
    fn a_language_is_named_by_its_code_or_name_and_told_only_to_a_model_that_takes_one() {
        let catalog = SpeechModelCatalog::bundled();
        let cohere = ChosenModel::Catalog(catalog.model("cohere-transcribe").unwrap());
        assert_eq!(told_language(&cohere, Some("German")).unwrap(), Some("de"));
        assert_eq!(told_language(&cohere, Some("ja")).unwrap(), Some("ja"));
        assert_eq!(told_language(&cohere, None).unwrap(), None, "the model's first");
        let error = told_language(&cohere, Some("Sinhala")).unwrap_err().to_string();
        assert!(error.contains("de (German)"), "{error}");

        let parakeet = ChosenModel::Catalog(catalog.model("parakeet-tdt-0.6b-v3").unwrap());
        assert_eq!(
            told_language(&parakeet, Some("de")).unwrap(),
            None,
            "it finds the language"
        );
    }

    #[test]
    fn progress_is_said_every_5_percent_and_at_the_end_of_each_stage() {
        let mut shown = None;
        let said: Vec<_> = [0, 3, 5, 9, 96, 100, 100]
            .into_iter()
            .map(|done| at(Stage::Downloading, done))
            .chain([at(Stage::Unpacking, 1), at(Stage::Unpacking, 100)])
            .filter(|&progress| {
                let due = is_due(progress, shown);
                if due {
                    shown = Some((progress.stage, progress.percent()));
                }
                due
            })
            .map(|progress| (progress.stage, progress.percent()))
            .collect();
        assert_eq!(
            said,
            [
                (Stage::Downloading, 0),
                (Stage::Downloading, 5),
                (Stage::Downloading, 96),
                (Stage::Downloading, 100),
                (Stage::Unpacking, 1),
                (Stage::Unpacking, 100),
            ]
        );
    }
}
