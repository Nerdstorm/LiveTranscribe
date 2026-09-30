//! `livetranscribe`, the Linux and Windows app: dictation, and transcribing audio files, with the
//! Mac app's speech to text.

// On Windows a windowed program, so the app opens no console window when it starts from the Start
// menu; it prints to the console it was started in, if any. Debug builds stay console programs.
#![cfg_attr(all(windows, not(debug_assertions)), windows_subsystem = "windows")]

#[cfg(any(target_os = "linux", windows))]
mod dictation;
#[cfg(any(target_os = "linux", windows))]
mod keys;
mod paths;
#[cfg(any(target_os = "linux", windows))]
mod settings;
mod speech_models;
mod transcribe;
mod wav;

use std::path::PathBuf;
use std::process::ExitCode;

use clap::{Parser, Subcommand};
use lt_transcription::qwen3_asr::DeviceChoice;
use tracing_subscriber::EnvFilter;

#[derive(Parser)]
#[command(
    name = "livetranscribe",
    version,
    about = "Dictation with the speech-to-text of Live Transcribe for Mac"
)]
struct Cli {
    /// What to do; without one, dictation (`run`), as when the app starts from the desktop's menu
    #[command(subcommand)]
    command: Option<Command>,
}

/// Which speech model to run, and where.
#[derive(Clone, clap::Args)]
struct ModelOptions {
    /// The speech model: one `livetranscribe models` lists, by its id, downloaded the first time
    /// it's used; or a folder tools/export-qwen3-asr.py wrote [default: qwen3-asr-0.6b-sinhala]
    #[arg(long, value_name = "MODEL")]
    model: Option<String>,
    /// Where a Qwen3-ASR model runs: auto (the NPU if there is one, and the CPU for what the NPU
    /// can't run), or only on one OpenVINO device: CPU, GPU or NPU. The other models run on the CPU
    #[arg(long, default_value = "auto", value_name = "DEVICE")]
    device: DeviceChoice,
    /// The language Cohere Transcribe writes, by its code or name, such as de or German; the
    /// other models find the language themselves [default: English]
    #[arg(long, value_name = "LANGUAGE")]
    language: Option<String>,
}

#[derive(Subcommand)]
enum Command {
    /// Dictation: hold the hotkey, speak, and the text is typed into the focused app. The tray's
    /// Settings… sets it up; the options here set it for one run
    #[cfg(any(target_os = "linux", windows))]
    Run(dictation::Options),
    /// Prints the name of each key pressed, for choosing the hotkey
    #[cfg(any(target_os = "linux", windows))]
    Keys,
    /// Lists the speech models this app can download, and which are downloaded
    Models,
    /// Transcribes WAV files and prints each transcript on a line
    Transcribe {
        #[command(flatten)]
        model: ModelOptions,
        /// WAV files, 16 kHz
        #[arg(required = true)]
        files: Vec<PathBuf>,
        /// Print a JSON object per file (its path, transcript, language, tokens and timing)
        #[arg(long)]
        json: bool,
    },
}

fn main() -> ExitCode {
    #[cfg(windows)]
    let has_console = lt_windows::attach_parent_console();
    // Quiet unless asked: LIVETRANSCRIBE_LOG=info (or debug) shows what the app does. Transcripts
    // are never logged.
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::try_from_env("LIVETRANSCRIBE_LOG").unwrap_or_else(|_| EnvFilter::new("warn")))
        .with_writer(std::io::stderr)
        .init();

    // An installed app runs on the OpenVINO it was installed with.
    if let Some(folder) = paths::bundled_openvino() {
        lt_transcription::qwen3_asr::use_openvino_in(folder);
    }

    let result = match Cli::parse().command {
        #[cfg(any(target_os = "linux", windows))]
        None => dictation::run(&dictation::Options::default()),
        #[cfg(not(any(target_os = "linux", windows)))]
        None => Err(anyhow::anyhow!("dictation isn't here on this system; see --help")),
        #[cfg(any(target_os = "linux", windows))]
        Some(Command::Run(options)) => dictation::run(&options),
        #[cfg(any(target_os = "linux", windows))]
        Some(Command::Keys) => keys::run(),
        Some(Command::Models) => transcribe::list_models(),
        Some(Command::Transcribe { model, files, json }) => transcribe::run(&model, &files, json),
    };
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("livetranscribe: {error:#}");
            // Started from the Start menu, there is no console to say it in.
            #[cfg(windows)]
            if !has_console {
                lt_windows::show_error(&format!("{error:#}"));
            }
            ExitCode::FAILURE
        }
    }
}
