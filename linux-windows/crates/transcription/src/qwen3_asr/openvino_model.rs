//! Qwen3-ASR's forward passes on OpenVINO, from a model folder that `tools/export-qwen3-asr.py`
//! wrote: `audio-conv`, `audio-encoder` and `text` (with its KV cache as state), plus the
//! checkpoint's tokenizer and `config.json`, and `manifest.json` describing them.
//!
//! OpenVINO's C API can't empty a request's state, so each reply runs on a new request of the
//! language model, whose cache starts empty.

use std::fmt;
use std::path::{Path, PathBuf};
use std::time::Instant;

use openvino::{
    CompiledModel, Core, DeviceType, ElementType, InferRequest, InferenceError, RwPropertyKey, SetupError, Shape,
    Tensor,
};
use serde::Deserialize;

use super::{ChunkFrames, Languages, MEL_BINS, Rows, SpeechModel, Tokenizer, TokenizerError, Transcriber};

/// The manifest format this build reads; `export-qwen3-asr.py` writes the same number.
const MANIFEST_FORMAT: u32 = 1;

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

/// Opens a model folder, its models compiled for `device` ("CPU", "GPU" or "NPU"), ready to
/// transcribe. `cache`, when given, keeps compiled models between runs, which makes the next
/// start faster.
pub fn open_transcriber(
    folder: &Path,
    device: &str,
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

/// Qwen3-ASR's passes, compiled for one device.
pub struct OpenVinoModel {
    conv: InferRequest,
    encoder: InferRequest,
    text: CompiledModel,
    // Kept for as long as their requests.
    _audio_models: [CompiledModel; 2],
    reply: Option<Reply>,
    audio_width: usize,
    text_width: usize,
    vocab_size: usize,
    // Dropped last: the compiled models came from it.
    _core: Core,
}

/// The language model's request for the reply being generated, and the position its next token
/// takes.
struct Reply {
    request: InferRequest,
    next_position: i64,
}

impl OpenVinoModel {
    fn load(folder: &Path, device: &str, cache: Option<&Path>) -> Result<(Self, Manifest), OpenVinoError> {
        let manifest = read_manifest(folder)?;
        let mut core = Core::new().map_err(OpenVinoError::Setup)?;
        let device_type = DeviceType::from(device);
        configure(&mut core, &device_type, cache);

        let mut conv = compile(&mut core, folder, "audio-conv", &device_type)?;
        let mut encoder = compile(&mut core, folder, "audio-encoder", &device_type)?;
        let text = compile(&mut core, folder, "text", &device_type)?;
        let model = Self {
            conv: request(&mut conv, "starting the audio convolutions")?,
            encoder: request(&mut encoder, "starting the audio encoder")?,
            text,
            _audio_models: [conv, encoder],
            reply: None,
            audio_width: manifest.audio.width,
            text_width: manifest.text.width,
            vocab_size: manifest.text.vocab_size,
            _core: core,
        };
        Ok((model, manifest))
    }

    /// The language model over `ids` at `positions`, with `rows` in place of the embeddings where
    /// `mask` is 1, continuing `request`'s cache. Returns the next token's logits.
    fn run_text(
        &self,
        request: &mut InferRequest,
        ids: &[i64],
        rows: &[f32],
        mask: &[i64],
        positions: &[i64],
    ) -> Result<Vec<f32>, OpenVinoError> {
        let length = ids.len();
        let feeds = [
            ("input_ids", tensor(ElementType::I64, &[1, length], ids)),
            (
                "audio_rows",
                tensor(ElementType::F32, &[1, length, self.text_width], rows),
            ),
            ("audio_mask", tensor(ElementType::I64, &[1, length], mask)),
            ("position_ids", tensor(ElementType::I64, &[1, length], positions)),
        ];
        for (name, feed) in feeds {
            let feed = feed.map_err(call("preparing the language model's input"))?;
            request
                .set_tensor(name, &feed)
                .map_err(call("setting the language model's input"))?;
        }
        request.infer().map_err(call("running the language model"))?;
        let (shape, logits) = output(request, "logits")?;
        if logits.len() != self.vocab_size {
            return Err(OpenVinoError::Output {
                pass: "language model",
                shape,
            });
        }
        Ok(logits)
    }
}

impl SpeechModel for OpenVinoModel {
    type Error = OpenVinoError;

    fn convolve(&mut self, chunks: &ChunkFrames) -> Result<Rows, OpenVinoError> {
        let input = tensor(
            ElementType::F32,
            &[chunks.count(), MEL_BINS, chunks.length()],
            chunks.values(),
        )
        .map_err(call("preparing the audio convolutions' input"))?;
        self.conv
            .set_tensor("chunks", &input)
            .map_err(call("setting the audio convolutions' input"))?;
        self.conv.infer().map_err(call("running the audio convolutions"))?;
        let (shape, values) = output(&self.conv, "rows")?;
        if shape.len() != 3 || shape[0] != to_dimension(chunks.count()) || shape[2] != to_dimension(self.audio_width) {
            return Err(OpenVinoError::Output {
                pass: "audio convolutions",
                shape,
            });
        }
        Ok(Rows::new(values, self.audio_width))
    }

    fn attend(&mut self, window: &Rows) -> Result<Rows, OpenVinoError> {
        let input = tensor(ElementType::F32, &[1, window.count(), window.width()], window.values())
            .map_err(call("preparing the audio encoder's input"))?;
        self.encoder
            .set_tensor("rows", &input)
            .map_err(call("setting the audio encoder's input"))?;
        self.encoder.infer().map_err(call("running the audio encoder"))?;
        let (shape, values) = output(&self.encoder, "embeddings")?;
        if shape.len() != 3 || shape[1] != to_dimension(window.count()) || shape[2] != to_dimension(self.text_width) {
            return Err(OpenVinoError::Output {
                pass: "audio encoder",
                shape,
            });
        }
        Ok(Rows::new(values, self.text_width))
    }

    fn prefill(&mut self, ids: &[u32], audio_start: usize, audio: &Rows) -> Result<Vec<f32>, OpenVinoError> {
        // A new request, so the cache starts empty.
        let mut request = self
            .text
            .create_infer_request()
            .map_err(call("starting the language model"))?;
        let width = self.text_width;
        let placed = audio.count().min(ids.len().saturating_sub(audio_start));
        let mut rows = vec![0.0; ids.len() * width];
        rows[audio_start * width..(audio_start + placed) * width].copy_from_slice(&audio.values()[..placed * width]);
        let mut mask = vec![0; ids.len()];
        mask[audio_start..audio_start + placed].fill(1);
        let ids: Vec<i64> = ids.iter().map(|&id| i64::from(id)).collect();
        let positions: Vec<i64> = (0..to_dimension(ids.len())).collect();

        let logits = self.run_text(&mut request, &ids, &rows, &mask, &positions)?;
        self.reply = Some(Reply {
            request,
            next_position: to_dimension(ids.len()),
        });
        Ok(logits)
    }

    fn step(&mut self, token: u32) -> Result<Vec<f32>, OpenVinoError> {
        let mut reply = self.reply.take().ok_or(OpenVinoError::NoReply)?;
        let rows = vec![0.0; self.text_width];
        let logits = self.run_text(
            &mut reply.request,
            &[i64::from(token)],
            &rows,
            &[0],
            &[reply.next_position],
        );
        reply.next_position += 1;
        self.reply = Some(reply);
        logits
    }
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
            "it holds {} in format {}; this build reads qwen3-asr in format {MANIFEST_FORMAT}",
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

/// Asks for low latency, keeps the language model's cache in 16-bit floats (the Mac's MLX keeps
/// it in 16 bits too; OpenVINO's CPU default is 8-bit), and caches compiled models. A property
/// the device refuses only costs speed, so it's logged and skipped.
fn configure(core: &mut Core, device: &DeviceType, cache: Option<&Path>) {
    let mut properties = vec![(RwPropertyKey::HintPerformanceMode, "LATENCY".to_owned())];
    if *device == DeviceType::CPU {
        properties.push((RwPropertyKey::Other("KV_CACHE_PRECISION".into()), "f16".to_owned()));
    }
    if let Some(cache) = cache.and_then(Path::to_str) {
        properties.push((RwPropertyKey::CacheDir, cache.to_owned()));
    }
    for (key, value) in properties {
        if let Err(error) = core.set_property(device, &key, &value) {
            tracing::warn!("OpenVINO refused {key:?} = {value} on {device}: {error}");
        }
    }
}

fn compile(core: &mut Core, folder: &Path, name: &str, device: &DeviceType) -> Result<CompiledModel, OpenVinoError> {
    let started = Instant::now();
    let path = |extension: &str| {
        let path = folder.join(format!("{name}.{extension}"));
        path.to_str().map(str::to_owned).ok_or_else(|| OpenVinoError::Folder {
            path: folder.to_owned(),
            problem: "its path isn't UTF-8".to_owned(),
        })
    };
    let model = core
        .read_model_from_file(&path("xml")?, &path("bin")?)
        .map_err(call("reading a model"))?;
    let compiled = core
        .compile_model(&model, device.to_owned())
        .map_err(call("compiling a model"))?;
    tracing::info!("Compiled {name} for {device} in {} ms", started.elapsed().as_millis());
    Ok(compiled)
}

fn request(model: &mut CompiledModel, doing: &'static str) -> Result<InferRequest, OpenVinoError> {
    model.create_infer_request().map_err(call(doing))
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
    use super::*;

    const MANIFEST: &str = r#"{"format": 1, "model": "qwen3-asr",
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
        let later = MANIFEST.replace(r#""format": 1"#, r#""format": 2"#);
        let error = parse_manifest(&later).unwrap_err();
        assert!(error.contains("format 2"), "{error}");

        let narrow = MANIFEST.replace(r#""output_width": 1024"#, r#""output_width": 896"#);
        assert!(parse_manifest(&narrow).is_err());
        assert!(parse_manifest("{}").is_err());
    }
}
