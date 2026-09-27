//! Qwen3-ASR's forward passes on OpenVINO, from a model folder that `tools/export-qwen3-asr.py`
//! wrote: `audio-conv`, `audio-encoder`, `text-embeddings` and `text` (with its KV cache as state),
//! plus the checkpoint's tokenizer and `config.json`, and `manifest.json` describing them.
//!
//! By default each pass runs on the NPU when there is one, and on the CPU when there isn't or the
//! NPU can't compile it ([`DeviceChoice`]). The NPU compiles only fixed shapes, so there the
//! convolutions take one chunk of [`CHUNK_FRAMES`] frames at a time, and the encoder a window
//! padded to [`NPU_WINDOW_ROWS`] rows, the padding masked out. The language model runs in the
//! NPU's LLM mode (NPUW), which fixes its shapes itself: a prompt of up to [`NPU_PROMPT_TOKENS`],
//! and a cache of [`NPU_TOKENS`] for the prompt and the reply together. A longer prompt goes to the
//! CPU, and a reply that outgrows the cache carries on there. The token embeddings, a table
//! lookup, always run on the CPU.
//!
//! OpenVINO's C API can't empty a request's state, so on the CPU each reply runs on a new request
//! of the language model, whose cache starts empty. The NPU's LLM mode starts its cache afresh with
//! each prompt, and there one request serves every reply: a second request of the same compiled
//! model fails on the NPU.

use std::convert::Infallible;
use std::fmt;
use std::path::{Path, PathBuf};
use std::str::FromStr;
use std::time::Instant;

use openvino::{
    CompiledModel, Core, DeviceType, ElementType, InferRequest, InferenceError, Model, PartialShape, RwPropertyKey,
    SetupError, Shape, Tensor,
};
use serde::Deserialize;

use super::encoder_layout::chunk_rows;
use super::{
    CHUNK_FRAMES, CHUNKS_PER_WINDOW, ChunkFrames, Languages, MEL_BINS, Rows, SpeechModel, Tokenizer, TokenizerError,
    Transcriber,
};

/// The manifest format this build reads; `export-qwen3-asr.py` writes the same number.
const MANIFEST_FORMAT: u32 = 2;

/// The encoder's window on the NPU: a whole window's rows, to which shorter windows are padded.
pub const NPU_WINDOW_ROWS: usize = CHUNKS_PER_WINDOW * chunk_rows(CHUNK_FRAMES);

/// The longest prompt the NPU's language model takes, in tokens: about 75 s of speech, at 13 audio
/// rows a second after the template's 20 tokens. Every prompt costs the NPU this many, so it isn't
/// set higher than dictation needs.
pub const NPU_PROMPT_TOKENS: usize = 1_024;

/// The NPU language model's cache: the prompt and the reply together. A reply gets at least 512
/// tokens, which is two minutes of English and one of Sinhala after the longest prompt.
pub const NPU_TOKENS: usize = NPU_PROMPT_TOKENS + 512;

/// Where the model runs: the app's `--device`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum DeviceChoice {
    /// The NPU when there is one, and the CPU for any pass the NPU can't compile.
    Auto,
    /// This device only (CPU, GPU or NPU), failing if it can't compile a pass. On the NPU, a
    /// prompt or reply longer than the NPU has room for still goes to the CPU.
    Only(String),
}

impl FromStr for DeviceChoice {
    type Err = Infallible;

    /// `auto`, or a device as OpenVINO names it; either in any case.
    fn from_str(name: &str) -> Result<Self, Infallible> {
        Ok(if name.eq_ignore_ascii_case("auto") {
            Self::Auto
        } else {
            Self::Only(name.to_ascii_uppercase())
        })
    }
}

/// What `manifest.json` says about a model folder.
#[derive(Debug, Deserialize)]
struct Manifest {
    format: u32,
    model: String,
    audio: AudioManifest,
    text: TextManifest,
}

#[derive(Debug, Deserialize)]
struct AudioManifest {
    mel_bins: usize,
    /// The convolutions' rows, which the attention layers read.
    width: usize,
    /// The encoder's output rows, which take the place of token embeddings.
    output_width: usize,
}

#[derive(Debug, Deserialize)]
struct TextManifest {
    width: usize,
    vocab_size: usize,
    audio_token_id: u32,
}

/// Why a model folder couldn't be used, or a pass failed.
#[derive(Debug)]
pub enum OpenVinoError {
    /// OpenVINO's library couldn't be found or started.
    Setup(SetupError),
    /// An OpenVINO call failed while `doing` something.
    Call {
        doing: &'static str,
        source: InferenceError,
    },
    /// The folder isn't one this build can read.
    Folder { path: PathBuf, problem: String },
    /// A pass returned a shape other than the manifest's.
    Output { pass: &'static str, shape: Vec<i64> },
    /// A pass was given more than the fixed shape it was compiled for holds.
    TooLong {
        pass: &'static str,
        length: usize,
        limit: usize,
    },
    /// A step was asked for before any prompt.
    NoReply,
}

impl fmt::Display for OpenVinoError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Setup(error) => write!(
                f,
                "OpenVINO couldn't start ({error}); install it and set INTEL_OPENVINO_DIR, or put its libraries on the library path"
            ),
            Self::Call { doing, source } => write!(f, "OpenVINO failed {doing}: {source}"),
            Self::Folder { path, problem } => write!(f, "{} isn't a usable model folder: {problem}", path.display()),
            Self::Output { pass, shape } => write!(f, "the {pass} returned an unexpected shape {shape:?}"),
            Self::TooLong { pass, length, limit } => {
                write!(
                    f,
                    "the {pass} was given {length}, more than the {limit} it was compiled for"
                )
            }
            Self::NoReply => f.write_str("the language model was asked for a step before a prompt"),
        }
    }
}

impl std::error::Error for OpenVinoError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Setup(error) => Some(error),
            Self::Call { source, .. } => Some(source),
            _ => None,
        }
    }
}

/// Why [`open_transcriber`] failed.
#[derive(Debug)]
pub enum OpenError {
    Model(OpenVinoError),
    Tokenizer(TokenizerError),
    /// `config.json` doesn't list the model's languages.
    Languages(serde_json::Error),
    Read {
        path: PathBuf,
        source: std::io::Error,
    },
}

impl fmt::Display for OpenError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Model(error) => error.fmt(f),
            Self::Tokenizer(error) => write!(f, "the model's tokenizer: {error}"),
            Self::Languages(error) => write!(f, "the model's config.json has no languages: {error}"),
            Self::Read { path, source } => write!(f, "couldn't read {}: {source}", path.display()),
        }
    }
}

impl std::error::Error for OpenError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Model(error) => Some(error),
            Self::Tokenizer(error) => Some(error),
            Self::Languages(error) => Some(error),
            Self::Read { source, .. } => Some(source),
        }
    }
}

/// Opens a model folder, its passes compiled where `device` says, ready to transcribe. `cache`,
/// when given, keeps compiled models between runs, which makes the next start faster.
pub fn open_transcriber(
    folder: &Path,
    device: &DeviceChoice,
    cache: Option<&Path>,
) -> Result<Transcriber<OpenVinoModel>, OpenError> {
    let (model, manifest) = OpenVinoModel::load(folder, device, cache).map_err(OpenError::Model)?;
    let tokenizer = Tokenizer::load(folder).map_err(OpenError::Tokenizer)?;
    let pad = tokenizer.id("<|audio_pad|>").map_err(OpenError::Tokenizer)?;
    if pad != manifest.text.audio_token_id {
        return Err(OpenError::Model(OpenVinoError::Folder {
            path: folder.to_owned(),
            problem: format!(
                "its models take audio at token {}, its tokenizer at {pad}",
                manifest.text.audio_token_id
            ),
        }));
    }
    let config_path = folder.join("config.json");
    let config = std::fs::read_to_string(&config_path).map_err(|source| OpenError::Read {
        path: config_path,
        source,
    })?;
    let languages = Languages::from_config(&config).map_err(OpenError::Languages)?;
    Transcriber::new(model, tokenizer, languages).map_err(OpenError::Tokenizer)
}

/// Qwen3-ASR's passes, each compiled for the device that runs it.
pub struct OpenVinoModel {
    // Requests go before the compiled models they came from, and those before the core.
    reply: Option<Reply>,
    conv: AudioPass,
    encoder: AudioPass,
    embeddings: InferRequest,
    text: TextModels,
    _compiled: Vec<CompiledModel>,
    audio_width: usize,
    text_width: usize,
    vocab_size: usize,
    core: Core,
}

/// An audio pass's request, where it runs, and the fixed length it takes there, if it does.
struct AudioPass {
    request: InferRequest,
    device: String,
    fixed: Option<usize>,
}

/// The language model: the NPU's when it compiled, and the CPU's (or the chosen device's, when
/// that isn't the NPU), compiled when first needed if the NPU's is there.
struct TextModels {
    npu: Option<NpuText>,
    cpu: Option<CompiledModel>,
    /// `text.xml` and `text.bin`, for compiling the CPU's later.
    files: [String; 2],
}

/// The language model in the NPU's LLM mode, and the one request that serves every reply.
struct NpuText {
    // The request goes before the compiled model it came from.
    request: TextRequest,
    _model: CompiledModel,
}

/// Where the reply being generated stands.
struct Reply {
    /// Its request on the CPU; `None` while the NPU's request runs it.
    cpu: Option<TextRequest>,
    /// Positions so far: the prompt's and the reply's.
    length: usize,
    /// Every position's embedding while the reply is on the NPU, for the CPU to carry on from if it
    /// outgrows the NPU's cache.
    embeddings: Vec<f32>,
}

/// A request of the language model, and whether its model takes beam_idx.
struct TextRequest {
    request: InferRequest,
    beam_idx: bool,
}

impl TextRequest {
    fn new(model: &mut CompiledModel) -> Result<Self, OpenVinoError> {
        // The exported model chooses its cache's rows through beam_idx; the NPU's LLM mode may
        // take that input away, having one reply at a time.
        let beam_idx = model.get_input_by_name("beam_idx").is_ok();
        let request = model
            .create_infer_request()
            .map_err(call("starting the language model"))?;
        Ok(Self { request, beam_idx })
    }

    /// The language model over `embeddings`, rows of `width`, at positions `first..` after the
    /// request's cache, and the next token's `vocab_size` logits.
    fn run(
        &mut self,
        embeddings: &[f32],
        first: usize,
        width: usize,
        vocab_size: usize,
    ) -> Result<Vec<f32>, OpenVinoError> {
        let length = embeddings.len() / width;
        let positions: Vec<i64> = (first..first + length).map(to_dimension).collect();
        let mut feeds = vec![
            (
                "inputs_embeds",
                tensor(ElementType::F32, &[1, length, width], embeddings),
            ),
            (
                "attention_mask",
                tensor(ElementType::I64, &[1, first + length], &vec![1_i64; first + length]),
            ),
            ("position_ids", tensor(ElementType::I64, &[1, length], &positions)),
        ];
        if self.beam_idx {
            feeds.push(("beam_idx", tensor(ElementType::I32, &[1], &[0_i32])));
        }
        for (name, feed) in feeds {
            let feed = feed.map_err(call("preparing the language model's input"))?;
            self.request
                .set_tensor(name, &feed)
                .map_err(call("setting the language model's input"))?;
        }
        self.request.infer().map_err(call("running the language model"))?;
        let (shape, logits) = output(&self.request, "logits")?;
        if logits.len() != vocab_size {
            return Err(OpenVinoError::Output {
                pass: "language model",
                shape,
            });
        }
        Ok(logits)
    }
}

impl OpenVinoModel {
    fn load(folder: &Path, choice: &DeviceChoice, cache: Option<&Path>) -> Result<(Self, Manifest), OpenVinoError> {
        let manifest = read_manifest(folder)?;
        let mut core = Core::new().map_err(OpenVinoError::Setup)?;
        let first = match choice {
            DeviceChoice::Auto if has_npu(&core) => "NPU".to_owned(),
            DeviceChoice::Auto => "CPU".to_owned(),
            DeviceChoice::Only(device) => device.clone(),
        };
        // Where a pass goes when `first` can't compile it: only when the choice was the app's.
        let fallback = (*choice == DeviceChoice::Auto && first != "CPU").then(|| "CPU".to_owned());
        configure(&mut core, "CPU", cache);
        if first != "CPU" {
            configure(&mut core, &first, cache);
        }
        let files = |name: &str| model_files(folder, name);
        let mut compiled = Vec::new();

        let mut compile_audio = |core: &mut Core, name: &'static str| -> Result<AudioPass, OpenVinoError> {
            let (model, device) =
                compile_with_fallback(core, &files(name)?, &first, fallback.as_deref(), |model, device| {
                    if device == "NPU" {
                        fix_audio_shape(model, name, manifest.audio.width)
                    } else {
                        Ok(())
                    }
                })?;
            let fixed = (device == "NPU").then_some(if name == "audio-conv" {
                CHUNK_FRAMES
            } else {
                NPU_WINDOW_ROWS
            });
            let mut model = model;
            let request = model.create_infer_request().map_err(call("starting an audio pass"))?;
            compiled.push(model);
            Ok(AudioPass { request, device, fixed })
        };
        let conv = compile_audio(&mut core, "audio-conv")?;
        let encoder = compile_audio(&mut core, "audio-encoder")?;

        let mut embedding_model = compile(&mut core, &files("text-embeddings")?, "CPU", &[], |_| Ok(()))?;
        let embeddings = embedding_model
            .create_infer_request()
            .map_err(call("starting the token embeddings"))?;
        compiled.push(embedding_model);

        let text_files = files("text")?;
        let (npu, cpu) = if first == "NPU" {
            match (compile_npu_text(&mut core, &text_files), &fallback) {
                (Ok(npu), _) => (Some(npu), None),
                (Err(error), Some(fallback)) => {
                    tracing::warn!("The NPU couldn't take the language model, so the {fallback} runs it: {error}");
                    (None, Some(compile(&mut core, &text_files, fallback, &[], |_| Ok(()))?))
                }
                (Err(error), None) => return Err(error),
            }
        } else {
            (None, Some(compile(&mut core, &text_files, &first, &[], |_| Ok(()))?))
        };

        let model = Self {
            reply: None,
            conv,
            encoder,
            embeddings,
            text: TextModels {
                npu,
                cpu,
                files: text_files,
            },
            _compiled: compiled,
            audio_width: manifest.audio.width,
            text_width: manifest.text.width,
            vocab_size: manifest.text.vocab_size,
            core,
        };
        tracing::info!("The speech model runs {}", model.placement());
        Ok((model, manifest))
    }

    /// Where each pass runs, for the log and the terminal: "convolutions on NPU, encoder on NPU,
    /// language model on NPU".
    pub fn placement(&self) -> String {
        let text = if self.text.npu.is_some() { "NPU" } else { "CPU" };
        format!(
            "convolutions on {}, encoder on {}, language model on {text}",
            self.conv.device, self.encoder.device
        )
    }

    /// The token embeddings of `ids`, one row per token.
    fn embed(&mut self, ids: &[u32]) -> Result<Vec<f32>, OpenVinoError> {
        let ids: Vec<i64> = ids.iter().map(|&id| i64::from(id)).collect();
        let input =
            tensor(ElementType::I64, &[1, ids.len()], &ids).map_err(call("preparing the token embeddings' input"))?;
        self.embeddings
            .set_tensor("input_ids", &input)
            .map_err(call("setting the token embeddings' input"))?;
        self.embeddings.infer().map_err(call("running the token embeddings"))?;
        let (shape, values) = output(&self.embeddings, "embeddings")?;
        if values.len() != ids.len() * self.text_width {
            return Err(OpenVinoError::Output {
                pass: "token embeddings",
                shape,
            });
        }
        Ok(values)
    }

    /// A new request of the CPU's language model, compiled now if it wasn't.
    fn cpu_text_request(&mut self) -> Result<TextRequest, OpenVinoError> {
        if self.text.cpu.is_none() {
            self.text.cpu = Some(compile(&mut self.core, &self.text.files, "CPU", &[], |_| Ok(()))?);
        }
        TextRequest::new(self.text.cpu.as_mut().expect("compiled just now"))
    }
}

impl SpeechModel for OpenVinoModel {
    type Error = OpenVinoError;

    fn convolve(&mut self, chunks: &ChunkFrames) -> Result<Rows, OpenVinoError> {
        let Some(fixed) = self.conv.fixed else {
            let rows = run_conv(
                &mut self.conv.request,
                chunks.values(),
                chunks.count(),
                chunks.length(),
                self.audio_width,
            )?;
            return Ok(Rows::new(rows, self.audio_width));
        };
        // One chunk at a time. The transcriber pads clips to a second, so every chunk has the
        // fixed frames; a shorter one, from a shorter clip, is padded with zeros, which changes
        // its last row or two a little from the CPU's, and its rows past its own are dropped.
        let length = chunks.length();
        if length > fixed {
            return Err(OpenVinoError::TooLong {
                pass: "audio convolutions",
                length,
                limit: fixed,
            });
        }
        let kept = chunk_rows(length) * self.audio_width;
        let mut rows = Vec::with_capacity(chunks.count() * kept);
        for chunk in chunks.values().chunks_exact(MEL_BINS * length) {
            let padded = pad_frames(chunk, length, fixed);
            let convolved = run_conv(&mut self.conv.request, &padded, 1, fixed, self.audio_width)?;
            rows.extend_from_slice(&convolved[..kept]);
        }
        Ok(Rows::new(rows, self.audio_width))
    }

    fn attend(&mut self, window: &Rows) -> Result<Rows, OpenVinoError> {
        let count = window.count();
        let length = self.encoder.fixed.unwrap_or(count);
        if count > length {
            return Err(OpenVinoError::TooLong {
                pass: "audio encoder",
                length: count,
                limit: length,
            });
        }
        let (rows, mask) = pad_window(window, length);
        let feeds = [
            ("rows", tensor(ElementType::F32, &[1, length, window.width()], &rows)),
            ("mask", tensor(ElementType::I64, &[1, length], &mask)),
        ];
        for (name, feed) in feeds {
            let feed = feed.map_err(call("preparing the audio encoder's input"))?;
            self.encoder
                .request
                .set_tensor(name, &feed)
                .map_err(call("setting the audio encoder's input"))?;
        }
        self.encoder
            .request
            .infer()
            .map_err(call("running the audio encoder"))?;
        let (shape, mut values) = output(&self.encoder.request, "embeddings")?;
        if shape.len() != 3 || shape[1] != to_dimension(length) || shape[2] != to_dimension(self.text_width) {
            return Err(OpenVinoError::Output {
                pass: "audio encoder",
                shape,
            });
        }
        values.truncate(count * self.text_width);
        Ok(Rows::new(values, self.text_width))
    }

    fn prefill(&mut self, ids: &[u32], audio_start: usize, audio: &Rows) -> Result<Vec<f32>, OpenVinoError> {
        let width = self.text_width;
        let mut embeddings = self.embed(ids)?;
        let placed = audio.count().min(ids.len().saturating_sub(audio_start));
        embeddings[audio_start * width..(audio_start + placed) * width]
            .copy_from_slice(&audio.values()[..placed * width]);
        // The last reply's request goes first, so two caches are never held at once.
        self.reply = None;
        let on_npu = self.text.npu.is_some() && ids.len() <= NPU_PROMPT_TOKENS;
        if self.text.npu.is_some() && !on_npu {
            tracing::info!(
                "A prompt of {} tokens is longer than the NPU's {NPU_PROMPT_TOKENS}, so the CPU runs it",
                ids.len()
            );
        }
        let vocab_size = self.vocab_size;
        let (cpu, logits) = if let Some(npu) = self.text.npu.as_mut().filter(|_| on_npu) {
            (None, npu.request.run(&embeddings, 0, width, vocab_size)?)
        } else {
            // A new request, so the cache starts empty.
            let mut request = self.cpu_text_request()?;
            let logits = request.run(&embeddings, 0, width, vocab_size)?;
            (Some(request), logits)
        };
        self.reply = Some(Reply {
            cpu,
            length: ids.len(),
            embeddings: if on_npu { embeddings } else { Vec::new() },
        });
        Ok(logits)
    }

    fn step(&mut self, token: u32) -> Result<Vec<f32>, OpenVinoError> {
        let (width, vocab_size) = (self.text_width, self.vocab_size);
        let mut reply = self.reply.take().ok_or(OpenVinoError::NoReply)?;
        let embedding = self.embed(&[token])?;
        let logits = if let Some(request) = reply.cpu.as_mut() {
            request.run(&embedding, reply.length, width, vocab_size)
        } else if reply.length < NPU_TOKENS {
            reply.embeddings.extend_from_slice(&embedding);
            let npu = self.text.npu.as_mut().expect("a reply on the NPU has the NPU's model");
            npu.request.run(&embedding, reply.length, width, vocab_size)
        } else {
            // The NPU's cache is full: the CPU takes the reply over from every position so far.
            tracing::info!("The reply outgrew the NPU's {NPU_TOKENS} tokens, so the CPU carries on");
            reply.embeddings.extend_from_slice(&embedding);
            let mut request = self.cpu_text_request()?;
            let logits = request.run(&reply.embeddings, 0, width, vocab_size);
            reply.cpu = Some(request);
            reply.embeddings = Vec::new();
            logits
        };
        reply.length += 1;
        self.reply = Some(reply);
        logits
    }
}

/// The convolutions over `count` chunks of `frames` frames, and their rows.
fn run_conv(
    request: &mut InferRequest,
    values: &[f32],
    count: usize,
    frames: usize,
    width: usize,
) -> Result<Vec<f32>, OpenVinoError> {
    let input = tensor(ElementType::F32, &[count, MEL_BINS, frames], values)
        .map_err(call("preparing the audio convolutions' input"))?;
    request
        .set_tensor("chunks", &input)
        .map_err(call("setting the audio convolutions' input"))?;
    request.infer().map_err(call("running the audio convolutions"))?;
    let (shape, rows) = output(request, "rows")?;
    if shape.len() != 3 || shape[0] != to_dimension(count) || shape[2] != to_dimension(width) {
        return Err(OpenVinoError::Output {
            pass: "audio convolutions",
            shape,
        });
    }
    Ok(rows)
}

/// One chunk's frames, band after band ([`MEL_BINS`] × `length`), padded with zeros to `frames`.
fn pad_frames(chunk: &[f32], length: usize, frames: usize) -> Vec<f32> {
    let mut padded = vec![0.0; MEL_BINS * frames];
    for (band, values) in chunk.chunks_exact(length).enumerate() {
        padded[band * frames..band * frames + length].copy_from_slice(values);
    }
    padded
}

/// `window`'s rows padded with zeros to `length`, and the mask that marks the real ones.
fn pad_window(window: &Rows, length: usize) -> (Vec<f32>, Vec<i64>) {
    let mut rows = window.values().to_vec();
    rows.resize(length * window.width(), 0.0);
    let mask = (0..length).map(|row| i64::from(row < window.count())).collect();
    (rows, mask)
}

/// Whether OpenVINO sees an NPU.
fn has_npu(core: &Core) -> bool {
    match core.available_devices() {
        Ok(devices) => devices.contains(&DeviceType::NPU),
        Err(error) => {
            tracing::warn!("OpenVINO couldn't list its devices, so the CPU runs the speech model: {error}");
            false
        }
    }
}

/// Fixes an audio model's shapes for the NPU: one chunk of [`CHUNK_FRAMES`] for the convolutions,
/// a window of [`NPU_WINDOW_ROWS`] for the encoder.
fn fix_audio_shape(model: &mut Model, name: &str, width: usize) -> Result<(), OpenVinoError> {
    let shape = |dimensions: &[usize]| {
        let dimensions: Vec<i64> = dimensions.iter().map(|&dimension| to_dimension(dimension)).collect();
        PartialShape::new_static(to_dimension(dimensions.len()), &dimensions).map_err(call("fixing a model's shape"))
    };
    let result = if name == "audio-conv" {
        model.reshape(&[("chunks", &shape(&[1, MEL_BINS, CHUNK_FRAMES])?)])
    } else {
        model.reshape(&[
            ("rows", &shape(&[1, NPU_WINDOW_ROWS, width])?),
            ("mask", &shape(&[1, NPU_WINDOW_ROWS])?),
        ])
    };
    result.map_err(call("fixing a model's shape"))
}

/// The language model in the NPU's LLM mode (NPUW), which compiles it as a prefill model for
/// prompts of up to [`NPU_PROMPT_TOKENS`] and a model for each next token over a cache of
/// [`NPU_TOKENS`], and its one request. The NPU takes its LLM mode only from the compilation's own
/// properties, not from the device's.
fn compile_npu_text(core: &mut Core, files: &[String; 2]) -> Result<NpuText, OpenVinoError> {
    let prompt = NPU_PROMPT_TOKENS.to_string();
    let reply = (NPU_TOKENS - NPU_PROMPT_TOKENS).to_string();
    let properties = [
        ("NPU_USE_NPUW", "YES"),
        ("NPUW_LLM", "YES"),
        ("NPUW_LLM_MAX_PROMPT_LEN", prompt.as_str()),
        ("NPUW_LLM_MIN_RESPONSE_LEN", reply.as_str()),
    ];
    let mut model = compile(core, files, "NPU", &properties, |_| Ok(()))?;
    let request = TextRequest::new(&mut model)?;
    Ok(NpuText { request, _model: model })
}

/// Compiles `files` for `first`, or for `fallback` if `first` can't and there is one. `prepare`
/// adapts the model to the device first. Returns the compiled model and its device.
fn compile_with_fallback(
    core: &mut Core,
    files: &[String; 2],
    first: &str,
    fallback: Option<&str>,
    prepare: impl Fn(&mut Model, &str) -> Result<(), OpenVinoError>,
) -> Result<(CompiledModel, String), OpenVinoError> {
    match compile(core, files, first, &[], |model| prepare(model, first)) {
        Ok(model) => Ok((model, first.to_owned())),
        Err(error) => {
            let Some(fallback) = fallback else {
                return Err(error);
            };
            tracing::warn!(
                "The {first} couldn't take {}, so the {fallback} runs it: {error}",
                files[0]
            );
            let model = compile(core, files, fallback, &[], |model| prepare(model, fallback))?;
            Ok((model, fallback.to_owned()))
        }
    }
}

/// Compiles `files` for `device`, with `properties` for this compilation only. `prepare` adapts
/// the model to the device first.
fn compile(
    core: &mut Core,
    files: &[String; 2],
    device: &str,
    properties: &[(&str, &str)],
    prepare: impl FnOnce(&mut Model) -> Result<(), OpenVinoError>,
) -> Result<CompiledModel, OpenVinoError> {
    let started = Instant::now();
    let mut model = core
        .read_model_from_file(&files[0], &files[1])
        .map_err(call("reading a model"))?;
    prepare(&mut model)?;
    let compiled = if properties.is_empty() {
        core.compile_model(&model, DeviceType::from(device))
    } else {
        core.compile_model_with_properties(&model, DeviceType::from(device), properties)
    }
    .map_err(call("compiling a model"))?;
    tracing::info!(
        "Compiled {} for {device} in {} ms",
        files[0],
        started.elapsed().as_millis()
    );
    Ok(compiled)
}

/// `name`'s `.xml` and `.bin` in `folder`.
fn model_files(folder: &Path, name: &str) -> Result<[String; 2], OpenVinoError> {
    let path = |extension: &str| {
        let path = folder.join(format!("{name}.{extension}"));
        path.to_str().map(str::to_owned).ok_or_else(|| OpenVinoError::Folder {
            path: folder.to_owned(),
            problem: "its path isn't UTF-8".to_owned(),
        })
    };
    Ok([path("xml")?, path("bin")?])
}

fn read_manifest(folder: &Path) -> Result<Manifest, OpenVinoError> {
    std::fs::read_to_string(folder.join("manifest.json"))
        .map_err(|error| format!("its manifest.json can't be read ({error})"))
        .and_then(|text| parse_manifest(&text))
        .map_err(|problem| OpenVinoError::Folder {
            path: folder.to_owned(),
            problem,
        })
}

/// The manifest, if this build can run the models it describes; otherwise what's wrong.
fn parse_manifest(text: &str) -> Result<Manifest, String> {
    let manifest: Manifest =
        serde_json::from_str(text).map_err(|error| format!("its manifest.json is malformed ({error})"))?;
    if manifest.format != MANIFEST_FORMAT || manifest.model != "qwen3-asr" {
        return Err(format!(
            "it holds {} in format {}; this build reads qwen3-asr in format {MANIFEST_FORMAT} (convert the model again \
             with tools/export-qwen3-asr.py)",
            manifest.model, manifest.format
        ));
    }
    if manifest.audio.mel_bins != MEL_BINS || manifest.audio.output_width != manifest.text.width {
        return Err(format!(
            "its audio encoder reads {} mel bands and writes rows of {}, for a language model of width {}",
            manifest.audio.mel_bins, manifest.audio.output_width, manifest.text.width
        ));
    }
    Ok(manifest)
}

/// Asks the device for low latency, keeps the CPU language model's cache in 16-bit floats (the
/// Mac's MLX keeps it in 16 bits too; OpenVINO's CPU default is 8-bit), and caches compiled
/// models. A property the device refuses only costs speed, so it's logged and skipped.
fn configure(core: &mut Core, device: &str, cache: Option<&Path>) {
    let device = DeviceType::from(device);
    let mut properties = vec![(RwPropertyKey::HintPerformanceMode, "LATENCY".to_owned())];
    if device == DeviceType::CPU {
        properties.push((RwPropertyKey::Other("KV_CACHE_PRECISION".into()), "f16".to_owned()));
    }
    if let Some(cache) = cache.and_then(Path::to_str) {
        properties.push((RwPropertyKey::CacheDir, cache.to_owned()));
    }
    for (key, value) in properties {
        if let Err(error) = core.set_property(&device, &key, &value) {
            tracing::warn!("OpenVINO refused {key:?} = {value} on {device}: {error}");
        }
    }
}

/// A tensor of `dimensions` holding `values`.
fn tensor<T: Copy>(element: ElementType, dimensions: &[usize], values: &[T]) -> Result<Tensor, InferenceError> {
    let dimensions: Vec<i64> = dimensions.iter().map(|&dimension| to_dimension(dimension)).collect();
    let mut tensor = Tensor::new(element, &Shape::new(&dimensions)?)?;
    tensor.get_data_mut::<T>()?.copy_from_slice(values);
    Ok(tensor)
}

/// An output's shape and its values.
fn output(request: &InferRequest, name: &'static str) -> Result<(Vec<i64>, Vec<f32>), OpenVinoError> {
    let tensor = request.get_tensor(name).map_err(call("reading an output"))?;
    let shape = tensor
        .get_shape()
        .map_err(call("reading an output's shape"))?
        .get_dimensions()
        .to_vec();
    let values = tensor.get_data::<f32>().map_err(call("reading an output"))?.to_vec();
    Ok((shape, values))
}

fn call(doing: &'static str) -> impl Fn(InferenceError) -> OpenVinoError {
    move |source| OpenVinoError::Call { doing, source }
}

fn to_dimension(count: usize) -> i64 {
    i64::try_from(count).expect("a tensor dimension fits in i64")
}

#[cfg(test)]
mod tests {
    use super::super::EncoderLayout;
    use super::*;

    const MANIFEST: &str = r#"{"format": 2, "model": "qwen3-asr",
        "audio": {"mel_bins": 128, "width": 896, "output_width": 1024},
        "text": {"width": 1024, "vocab_size": 151936, "layers": 28, "audio_token_id": 151676}}"#;

    #[test]
    fn reads_the_exporters_manifest() {
        let manifest = parse_manifest(MANIFEST).unwrap();
        assert_eq!(manifest.audio.width, 896);
        assert_eq!(manifest.text.audio_token_id, 151_676);
    }

    #[test]
    fn refuses_another_format_or_mismatched_widths() {
        let earlier = MANIFEST.replace(r#""format": 2"#, r#""format": 1"#);
        let error = parse_manifest(&earlier).unwrap_err();
        assert!(
            error.contains("format 1") && error.contains("convert the model again"),
            "{error}"
        );

        let narrow = MANIFEST.replace(r#""output_width": 1024"#, r#""output_width": 896"#);
        assert!(parse_manifest(&narrow).is_err());
        assert!(parse_manifest("{}").is_err());
    }

    #[test]
    fn the_device_is_auto_or_one_that_openvino_names() {
        let parse = |name: &str| name.parse::<DeviceChoice>().unwrap();
        assert_eq!(parse("auto"), DeviceChoice::Auto);
        assert_eq!(parse("AUTO"), DeviceChoice::Auto);
        assert_eq!(parse("npu"), DeviceChoice::Only("NPU".to_owned()));
        assert_eq!(parse("CPU"), DeviceChoice::Only("CPU".to_owned()));
    }

    #[test]
    fn the_npus_window_holds_the_longest_window_of_a_clip() {
        let longest = EncoderLayout::new(3_000)
            .windows()
            .iter()
            .map(std::ops::Range::len)
            .max()
            .unwrap();
        assert_eq!(NPU_WINDOW_ROWS, longest);
        assert_eq!(NPU_WINDOW_ROWS, 104);
    }

    #[test]
    fn a_short_chunk_is_padded_band_by_band() {
        // Two bands of a three-frame chunk, as the MEL_BINS-band layout lays them out.
        let chunk: Vec<f32> = (1..=(MEL_BINS * 3)).map(|value| value as f32).collect();
        let padded = pad_frames(&chunk, 3, 5);
        assert_eq!(padded.len(), MEL_BINS * 5);
        assert_eq!(&padded[..5], [1.0, 2.0, 3.0, 0.0, 0.0]);
        assert_eq!(&padded[5..10], [4.0, 5.0, 6.0, 0.0, 0.0]);
    }

    #[test]
    fn a_short_window_is_padded_and_its_padding_masked() {
        let window = Rows::new(vec![1.0, 2.0, 3.0, 4.0], 2);
        let (rows, mask) = pad_window(&window, 4);
        assert_eq!(rows, [1.0, 2.0, 3.0, 4.0, 0.0, 0.0, 0.0, 0.0]);
        assert_eq!(mask, [1, 1, 0, 0]);
    }
}
