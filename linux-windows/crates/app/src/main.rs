//! `livetranscribe`, the Linux (and later Windows) app: dictation, and transcribing audio files,
//! with the Mac app's speech to text.

#[cfg(target_os = "linux")]
mod dictation;
#[cfg(target_os = "linux")]
mod keys;
mod paths;
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
    #[command(subcommand)]
    command: Command,
}

/// Which speech model to run, and where.
#[derive(Clone, clap::Args)]
struct ModelOptions {
    /// The model folder tools/export-qwen3-asr.py wrote [default: the app's data folder's
    /// models/qwen3-asr-0.6b-v2]
    #[arg(long, value_name = "FOLDER")]
    model: Option<PathBuf>,
    /// Where the model runs: auto (the NPU if there is one, and the CPU for what the NPU can't
    /// run), or only on one OpenVINO device: CPU, GPU or NPU
    #[arg(long, default_value = "auto", value_name = "DEVICE")]
    device: DeviceChoice,
}

#[derive(Subcommand)]
enum Command {
    /// Dictation: hold the hotkey, speak, and the text is typed into the focused app
    #[cfg(target_os = "linux")]
    Run(dictation::Options),
    /// Prints the name of each key pressed, for choosing the hotkey
    #[cfg(target_os = "linux")]
    Keys,
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
    // Quiet unless asked: LIVETRANSCRIBE_LOG=info (or debug) shows what the app does. Transcripts
    // are never logged.
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::try_from_env("LIVETRANSCRIBE_LOG").unwrap_or_else(|_| EnvFilter::new("warn")))
        .with_writer(std::io::stderr)
        .init();

    let result = match Cli::parse().command {
        #[cfg(target_os = "linux")]
        Command::Run(options) => dictation::run(&options),
        #[cfg(target_os = "linux")]
        Command::Keys => keys::run(),
        Command::Transcribe { model, files, json } => transcribe::run(&model, &files, json),
    };
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("livetranscribe: {error:#}");
            ExitCode::FAILURE
        }
    }
}
