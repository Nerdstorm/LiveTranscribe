//! The catalog's models other than our Qwen3-ASR, run by sherpa-onnx (k2-fsa, Apache-2.0) on the
//! CPU: Parakeet and Cohere Transcribe, as sherpa-onnx publishes them. The NPU stays with the
//! Qwen3-ASR models' own OpenVINO runtime: sherpa-onnx's prebuilt ONNX Runtime has no OpenVINO in
//! it, and a second OpenVINO in the process could clash with the first.
//!
//! The libraries linked are sherpa-onnx's speech-only ones (see linux-windows/.cargo/config.toml).
//! sherpa-onnx checks only that a model's files exist. A file ONNX Runtime can't read throws a C++
//! exception through sherpa-onnx's C API, which aborts the process ("Rust cannot catch foreign
//! exceptions"), so a model is opened only once [`crate::catalog`] has checked each of its files
//! against its SHA-256 ([`crate::speech_to_text::SpeechToText::open`]).

use std::fmt;
use std::path::{Path, PathBuf};
use std::time::Instant;

use lt_shared::audio_format::{SAMPLE_RATE, samples_for_milliseconds};
use serde::Deserialize;
use sherpa_onnx::{
    OfflineCohereTranscribeModelConfig, OfflineModelConfig, OfflineRecognizer, OfflineRecognizerConfig,
    OfflineTransducerModelConfig,
};

use crate::catalog::{ModelFile, Role};
use crate::qwen3_asr::MAX_CLIP_SAMPLES;

/// A model's family, which says which of its files are which and how sherpa-onnx runs it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Family {
    /// NVIDIA's NeMo transducers, Parakeet TDT among them: an encoder, a decoder and a joiner.
    NemoTransducer,
    /// Cohere Transcribe: an encoder, whose weights may be in a file beside it, and a decoder.
    CohereTranscribe,
}

impl Family {
    /// The roles of the files a model of this family has, each exactly once.
    pub fn roles(self) -> &'static [Role] {
        match self {
            Self::NemoTransducer => &[Role::Encoder, Role::Decoder, Role::Joiner, Role::Tokens],
            Self::CohereTranscribe => &[Role::Encoder, Role::Decoder, Role::Tokens],
        }
    }

    /// Points `config` at the files, whose paths `path` gives by role.
    fn configure(self, config: &mut OfflineModelConfig, path: impl Fn(Role) -> String) {
        match self {
            Self::NemoTransducer => {
                config.transducer = OfflineTransducerModelConfig {
                    encoder: Some(path(Role::Encoder)),
                    decoder: Some(path(Role::Decoder)),
                    joiner: Some(path(Role::Joiner)),
                };
                // Named, so sherpa-onnx needn't open the encoder to find out.
                config.model_type = Some("nemo_transducer".to_owned());
            }
            Self::CohereTranscribe => {
                config.cohere_transcribe = OfflineCohereTranscribeModelConfig {
                    encoder: Some(path(Role::Encoder)),
                    decoder: Some(path(Role::Decoder)),
                    // The model can't tell the language; the Mac's mlx-audio-swift asks for
                    // English too.
                    language: Some(COHERE_LANGUAGE.to_owned()),
                    use_punct: true,
                    use_itn: true,
                };
            }
        }
        config.tokens = Some(path(Role::Tokens));
    }
}

/// The language Cohere Transcribe is asked to write.
const COHERE_LANGUAGE: &str = "en";

/// Clips shorter than 100 ms hold no word, so they give no text without running the model, as
/// with [`crate::qwen3_asr`].
const MINIMUM_SAMPLES: usize = samples_for_milliseconds(100);

/// Why a model couldn't be opened.
#[derive(Debug)]
pub enum OpenError {
    /// The model has no file for a role its family needs.
    NoFile(Role),
    /// A file's path isn't Unicode, which sherpa-onnx takes paths in.
    NotUnicode(PathBuf),
    /// sherpa-onnx couldn't load the model, and said why on standard error.
    Refused { folder: PathBuf },
}

impl fmt::Display for OpenError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NoFile(role) => write!(f, "the model has no {role:?} file"),
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
    /// The clip is longer than [`MAX_CLIP_SAMPLES`].
    TooLong { samples: usize },
    /// sherpa-onnx returned no result.
    NoResult,
}

impl fmt::Display for TranscribeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::TooLong { samples } => write!(
                f,
                "a clip of {} s is longer than the {} s that can be transcribed at once",
                samples / SAMPLE_RATE,
                MAX_CLIP_SAMPLES / SAMPLE_RATE
            ),
            Self::NoResult => write!(f, "sherpa-onnx returned no transcript"),
        }
    }
}

impl std::error::Error for TranscribeError {}

/// A clip's transcript, and how many tokens it took.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SherpaTranscript {
    pub text: String,
    pub tokens: usize,
}

/// Transcribes clips with one model. Open it once: loading takes about as long, and as much
/// memory, as the model's size.
pub struct SherpaTranscriber {
    recognizer: OfflineRecognizer,
    family: Family,
    threads: usize,
}

impl SherpaTranscriber {
    /// Opens the model of `family` whose `files` are in `folder`, to run on `threads` of the CPU's
    /// threads. Each file must have been checked first (see the module's documentation).
    pub(crate) fn open(folder: &Path, family: Family, files: &[ModelFile], threads: usize) -> Result<Self, OpenError> {
        let mut paths = Vec::with_capacity(family.roles().len());
        for &role in family.roles() {
            let file = files
                .iter()
                .find(|file| file.role == Some(role))
                .ok_or(OpenError::NoFile(role))?;
            let path = folder.join(&file.name);
            let text = path.to_str().map(str::to_owned).ok_or(OpenError::NotUnicode(path))?;
            paths.push((role, text));
        }
        let path = |role: Role| {
            paths
                .iter()
                .find(|(found, _)| *found == role)
                .map(|(_, path)| path.clone())
                .unwrap_or_default()
        };

        let mut config = OfflineRecognizerConfig::default();
        family.configure(&mut config.model_config, path);
        let threads = threads.max(1);
        config.model_config.num_threads = i32::try_from(threads).unwrap_or(i32::MAX);
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
        Ok(Self {
            recognizer,
            family,
            threads,
        })
    }

    /// The model's family.
    pub fn family(&self) -> Family {
        self.family
    }

    /// How many of the CPU's threads it runs on.
    pub fn threads(&self) -> usize {
        self.threads
    }

    /// The transcript of `samples`, 16 kHz mono.
    pub fn transcribe(&self, samples: &[f32]) -> Result<SherpaTranscript, TranscribeError> {
        if samples.len() < MINIMUM_SAMPLES {
            return Ok(SherpaTranscript {
                text: String::new(),
                tokens: 0,
            });
        }
        if samples.len() > MAX_CLIP_SAMPLES {
            return Err(TranscribeError::TooLong { samples: samples.len() });
        }
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
        Ok(SherpaTranscript {
            text: result.text.trim().to_owned(),
            tokens: result.tokens.len(),
        })
    }
}

/// How many threads a model gets: one per core, counting two threads of a core as one (ONNX
/// Runtime's matrix work gains little from a core's second thread), from 1 to 8.
pub fn default_threads() -> usize {
    let logical = std::thread::available_parallelism().map_or(1, usize::from);
    (logical / 2).clamp(1, 8)
}
