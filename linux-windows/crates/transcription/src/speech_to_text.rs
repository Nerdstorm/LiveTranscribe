//! One speech-to-text model, whichever engine runs it: our Qwen3-ASR runtime on OpenVINO
//! ([`crate::qwen3_asr`]), or sherpa-onnx for the catalog's other models ([`crate::sherpa`]).

use std::fmt;
use std::path::Path;

use crate::catalog::{Engine, LanguageChoice, VerifiedModel, chosen_language};
use crate::qwen3_asr::{self, DeviceChoice, OpenVinoModel, Transcriber, open_transcriber};
use crate::sherpa::{self, SherpaTranscriber};

/// A clip's transcript, and what it took.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Transcript {
    pub text: String,
    /// The language the model named, or was told to write, where there is one.
    pub language: Option<String>,
    /// Tokens in the transcript.
    pub tokens: usize,
}

/// A loaded model.
pub enum SpeechToText {
    Qwen3Asr {
        transcriber: Box<Transcriber<OpenVinoModel>>,
        /// The languages it can be told, from the catalog; none for a model outside it.
        languages: Vec<LanguageChoice>,
    },
    SherpaOnnx(SherpaTranscriber),
}

/// Why a model couldn't be opened.
#[derive(Debug)]
pub enum OpenError {
    Qwen3Asr(qwen3_asr::OpenError),
    SherpaOnnx(sherpa::OpenError),
}

impl fmt::Display for OpenError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Qwen3Asr(error) => error.fmt(f),
            Self::SherpaOnnx(error) => error.fmt(f),
        }
    }
}

impl std::error::Error for OpenError {}

/// Why a clip wasn't transcribed.
#[derive(Debug)]
pub enum TranscribeError {
    Qwen3Asr(qwen3_asr::TranscribeError<qwen3_asr::OpenVinoError>),
    SherpaOnnx(sherpa::TranscribeError),
}

impl fmt::Display for TranscribeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Qwen3Asr(error) => error.fmt(f),
            Self::SherpaOnnx(error) => error.fmt(f),
        }
    }
}

impl std::error::Error for TranscribeError {}

impl SpeechToText {
    /// Opens a catalog model, once its files are checked. `device` and `cache` (where OpenVINO
    /// keeps compiled models) are for the OpenVINO models; sherpa-onnx runs on the CPU.
    pub fn open(model: &VerifiedModel<'_>, device: &DeviceChoice, cache: Option<&Path>) -> Result<Self, OpenError> {
        match &model.model().engine {
            Engine::OpenVino { .. } => {
                Self::open_qwen3_asr(model.folder(), device, cache, &model.model().language_choices)
            }
            Engine::SherpaOnnx { family, .. } => SherpaTranscriber::open(
                model.folder(),
                *family,
                &model.model().files,
                &model.model().language_choices,
                model.model().automatic_language.as_deref(),
                sherpa::default_threads(),
            )
            .map(Self::SherpaOnnx)
            .map_err(OpenError::SherpaOnnx),
        }
    }

    /// Opens a Qwen3-ASR model the setup kit converted into `folder`, outside the catalog. It
    /// isn't told a language.
    pub fn open_converted(folder: &Path, device: &DeviceChoice, cache: Option<&Path>) -> Result<Self, OpenError> {
        Self::open_qwen3_asr(folder, device, cache, &[])
    }

    fn open_qwen3_asr(
        folder: &Path,
        device: &DeviceChoice,
        cache: Option<&Path>,
        languages: &[LanguageChoice],
    ) -> Result<Self, OpenError> {
        open_transcriber(folder, device, cache)
            .map(|transcriber| Self::Qwen3Asr {
                transcriber: Box::new(transcriber),
                languages: languages.to_vec(),
            })
            .map_err(OpenError::Qwen3Asr)
    }

    /// The transcript of `samples`, 16 kHz mono. `language` is the Language setting
    /// (`sttLanguage`, a code, `None` for Automatic): a model that can be told which language to
    /// write writes it if it's one of its languages, and otherwise Automatic's: Qwen3-ASR finds
    /// the language, and Cohere Transcribe writes English. Parakeet always finds it.
    pub fn transcribe(&mut self, samples: &[f32], language: Option<&str>) -> Result<Transcript, TranscribeError> {
        match self {
            Self::Qwen3Asr { transcriber, languages } => transcriber
                .transcribe(
                    samples,
                    chosen_language(languages, None, language).map(|choice| choice.name.as_str()),
                )
                .map(|transcription| Transcript {
                    text: transcription.text,
                    language: transcription.language,
                    tokens: transcription.tokens,
                })
                .map_err(TranscribeError::Qwen3Asr),
            Self::SherpaOnnx(transcriber) => transcriber
                .transcribe(samples, language)
                .map(|transcript| Transcript {
                    text: transcript.text,
                    language: transcript.language,
                    tokens: transcript.tokens,
                })
                .map_err(TranscribeError::SherpaOnnx),
        }
    }

    /// Where the model's passes run, as the terminal and Settings say it.
    pub fn placement(&self) -> String {
        match self {
            Self::Qwen3Asr { transcriber, .. } => transcriber.model().placement(),
            Self::SherpaOnnx(transcriber) => format!("CPU, {} threads (sherpa-onnx)", transcriber.threads()),
        }
    }
}
