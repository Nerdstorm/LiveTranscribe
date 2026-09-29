//! The catalog's models other than our Qwen3-ASR, run by sherpa-onnx (k2-fsa, Apache-2.0) on the
//! CPU: Moonshine first, then Parakeet, Whisper and Canary. The NPU stays with the Qwen3-ASR
//! models' own OpenVINO runtime: sherpa-onnx's prebuilt ONNX Runtime has no OpenVINO in it, and a
//! second OpenVINO in the process could clash with the first.
//!
//! The libraries linked are sherpa-onnx's speech-only ones (see linux-windows/.cargo/config.toml).
//! sherpa-onnx checks only that a model's files exist. A file ONNX Runtime can't read throws a C++
//! exception through sherpa-onnx's C API, which aborts the process ("Rust cannot catch foreign
//! exceptions"), so check a model's files against their SHA-256 before opening them here.

use std::fmt;
use std::path::{Path, PathBuf};
use std::time::Instant;

use lt_shared::audio_format::SAMPLE_RATE;
use sherpa_onnx::{OfflineModelConfig, OfflineRecognizer, OfflineRecognizerConfig};

/// A model's family, which says which of its files are which.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Family {
    /// Moonshine v2 (Useful Sensors, 2026), as sherpa-onnx publishes it: `encoder_model.ort`,
    /// `decoder_model_merged.ort` and `tokens.txt`.
    MoonshineV2,
}

impl Family {
    /// The files a model of this family has, by name in its folder.
    pub fn files(self) -> &'static [&'static str] {
        match self {
            Self::MoonshineV2 => &["encoder_model.ort", "decoder_model_merged.ort", "tokens.txt"],
        }
    }

    /// Points `config` at the files, given in the order [`Self::files`] names them.
    fn configure(self, config: &mut OfflineModelConfig, files: Vec<String>) {
        let mut files = files.into_iter();
        match self {
            Self::MoonshineV2 => {
                config.moonshine.encoder = files.next();
                config.moonshine.merged_decoder = files.next();
                config.tokens = files.next();
            }
        }
    }
}

/// Why a model couldn't be opened.
#[derive(Debug)]
pub enum OpenError {
    /// A file the model's family has isn't in its folder.
    Missing(PathBuf),
    /// A file's path isn't Unicode, which sherpa-onnx takes paths in.
    NotUnicode(PathBuf),
    /// sherpa-onnx couldn't load the model, and said why on standard error.
    Refused { folder: PathBuf },
}

impl fmt::Display for OpenError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Missing(path) => write!(f, "the model has no {}", path.display()),
            Self::NotUnicode(path) => write!(f, "sherpa-onnx can't open {}: its path isn't Unicode", path.display()),
            Self::Refused { folder } => write!(
                f,
                "sherpa-onnx couldn't load the model in {} (its reason is in the log's standard error)",
                folder.display()
            ),
        }
    }
}

impl std::error::Error for OpenError {}

/// Why a clip wasn't transcribed.
#[derive(Debug)]
pub enum TranscribeError {
    /// sherpa-onnx returned no result.
    NoResult,
}

impl fmt::Display for TranscribeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NoResult => write!(f, "sherpa-onnx returned no transcript"),
        }
    }
}

impl std::error::Error for TranscribeError {}

/// Transcribes clips with one model. Open it once: loading takes about as long, and as much
/// memory, as the model's size.
pub struct SherpaTranscriber {
    recognizer: OfflineRecognizer,
    family: Family,
}

impl SherpaTranscriber {
    /// Opens the model of `family` in `folder`, to run on `threads` of the CPU's threads.
    pub fn open(folder: &Path, family: Family, threads: usize) -> Result<Self, OpenError> {
        let files = family
            .files()
            .iter()
            .map(|name| {
                let path = folder.join(name);
                if !path.is_file() {
                    return Err(OpenError::Missing(path));
                }
                path.to_str().map(str::to_owned).ok_or(OpenError::NotUnicode(path))
            })
            .collect::<Result<Vec<_>, _>>()?;

        let mut config = OfflineRecognizerConfig::default();
        family.configure(&mut config.model_config, files);
        config.model_config.num_threads = i32::try_from(threads.max(1)).unwrap_or(i32::MAX);
        config.model_config.provider = Some("cpu".to_owned());

        let started = Instant::now();
        let recognizer = OfflineRecognizer::create(&config).ok_or_else(|| OpenError::Refused {
            folder: folder.to_owned(),
        })?;
        tracing::info!(
            "Loaded {family:?} from {} in {:.1} s",
            folder.display(),
            started.elapsed().as_secs_f32()
        );
        Ok(Self { recognizer, family })
    }

    /// The model's family.
    pub fn family(&self) -> Family {
        self.family
    }

    /// The transcript of `samples`, 16 kHz mono.
    pub fn transcribe(&self, samples: &[f32]) -> Result<String, TranscribeError> {
        let started = Instant::now();
        let stream = self.recognizer.create_stream();
        stream.accept_waveform(SAMPLE_RATE as i32, samples);
        self.recognizer.decode(&stream);
        let result = stream.get_result().ok_or(TranscribeError::NoResult)?;
        tracing::debug!(
            "Transcribed {} ms of audio in {} ms: {} tokens",
            samples.len() * 1_000 / SAMPLE_RATE,
            started.elapsed().as_millis(),
            result.tokens.len()
        );
        Ok(result.text.trim().to_owned())
    }
}
