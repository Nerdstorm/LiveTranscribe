//! A Qwen3 language model's forward passes on OpenVINO, from the model as optimum-intel exports it
//! (`openvino_model.xml` and `.bin`, as in OpenVINO/Qwen3-1.7B-int4-ov): one stateful model, whose
//! KV cache is its state, that takes `input_ids`, `attention_mask`, `position_ids` and `beam_idx`
//! and returns `logits`.
//!
//! A model exported with adapter inputs (`tools/export-qwen3-cleanup.py`) also takes, for each
//! projection it adapts, the two matrices of a LoRA branch (`….lora_a` and `….lora_b`): in 32-bit
//! floats with the adapter's scale folded into B, or in 16-bit ones with the scale an input of its
//! own (`adapter_scale`). A reply binds an [`Adapter`]'s matrices to them, or, without one, rank-1
//! zeros, which leave the base model's outputs as they are.
//!
//! OpenVINO's C API can't empty a request's state, so on the CPU (or GPU) each reply runs on a new
//! request, whose cache starts empty. On the NPU the model runs in the NPU's LLM mode (NPUW), which
//! starts its cache afresh with each prompt, and one request serves every reply: a second request
//! of the same compiled model fails there. The NPU fixes the prompt's and the cache's lengths when
//! it compiles ([`NPU_PROMPT_TOKENS`], [`NPU_REPLY_TOKENS`]).

use std::fmt;
use std::path::{Path, PathBuf};
use std::time::Instant;

use openvino::{
    CompiledModel, Core, DeviceType, ElementType, InferRequest, InferenceError, Model, SetupError, Shape, Tensor,
};

use crate::adapter::Adapter;
use crate::runtime::{self, RuntimeError};

/// The model's weights and graph, in the folder.
pub const MODEL_XML: &str = "openvino_model.xml";
pub const MODEL_BIN: &str = "openvino_model.bin";

/// The input that scales the adapter's branch, in a model exported to take it.
pub const ADAPTER_SCALE: &str = "adapter_scale";
/// How the names of an adapted projection's matrices end: A, `[in, rank]`, and B, `[rank, out]`.
pub const LORA_A: &str = ".lora_a";
pub const LORA_B: &str = ".lora_b";

/// The longest prompt the NPU's LLM mode takes, and the least room it keeps for the reply after
/// it. A cleanup prompt is a few hundred tokens; a reply with thinking up to about a thousand.
pub const NPU_PROMPT_TOKENS: usize = 1_024;
pub const NPU_REPLY_TOKENS: usize = 1_024;

/// Where the model runs and how OpenVINO is set up for it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Options {
    /// The OpenVINO device: `CPU` (the default), `GPU` or `NPU`.
    pub device: String,
    /// Where OpenVINO keeps compiled models between runs, which makes the next start faster.
    pub cache: Option<PathBuf>,
    /// More properties for the compilation, such as `KV_CACHE_PRECISION` or
    /// `INFERENCE_NUM_THREADS`, over this module's own. OpenVINO takes eight at most, these
    /// included.
    pub properties: Vec<(String, String)>,
}

impl Default for Options {
    fn default() -> Self {
        Self {
            device: "CPU".to_owned(),
            cache: None,
            properties: Vec::new(),
        }
    }
}

/// Why the model couldn't be opened, or a pass failed.
#[derive(Debug)]
pub enum ModelError {
    /// The OpenVINO runtime the app was installed with couldn't be loaded.
    Runtime(RuntimeError),
    /// OpenVINO's library couldn't be found or started.
    Setup(SetupError),
    /// An OpenVINO call failed while `doing` something.
    Call {
        doing: &'static str,
        source: InferenceError,
    },
    /// The folder isn't a model this build can run.
    Folder { path: PathBuf, problem: String },
    /// The model returned logits of an unexpected shape.
    Output { shape: Vec<i64> },
    /// The prompt is longer than the NPU's LLM mode was compiled for.
    TooLong { tokens: usize, limit: usize },
    /// A step was asked for before any prompt.
    NoReply,
    /// An adapter was bound to a model without adapter inputs.
    NoAdapterInputs { adapter: String },
}

impl fmt::Display for ModelError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Runtime(error) => error.fmt(f),
            Self::Setup(error) => write!(
                f,
                "OpenVINO couldn't start ({error}); install it and set INTEL_OPENVINO_DIR, or put its libraries on the library path"
            ),
            Self::Call { doing, source } => write!(f, "OpenVINO failed {doing}: {source}"),
            Self::Folder { path, problem } => write!(f, "{} isn't a usable model folder: {problem}", path.display()),
            Self::Output { shape } => write!(f, "the language model returned logits of shape {shape:?}"),
            Self::TooLong { tokens, limit } => write!(
                f,
                "a prompt of {tokens} tokens is longer than the {limit} the NPU's language model was compiled for"
            ),
            Self::NoReply => f.write_str("the language model was asked for a step before a prompt"),
            Self::NoAdapterInputs { adapter } => write!(
                f,
                "the adapter {adapter:?} was asked for, and the language model was exported without adapter inputs"
            ),
        }
    }
}

impl std::error::Error for ModelError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Runtime(error) => Some(error),
            Self::Setup(error) => Some(error),
            Self::Call { source, .. } => Some(source),
            _ => None,
        }
    }
}

/// One matrix of an adapted projection's low-rank branch: an input of a model exported with
/// adapter inputs, A (`….lora_a`, `[in, rank]`) or B (`….lora_b`, `[rank, out]`), of any rank.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AdapterInput {
    /// As an adapter's file names the matrix: `model.layers.12.self_attn.q_proj.lora_a`.
    pub name: String,
    /// 16- or 32-bit floats.
    pub element: ElementType,
    /// The dimension the model fixes: the projection's inputs for A, its outputs for B.
    pub fixed: usize,
}

impl AdapterInput {
    /// The matrix's shape at `rank`.
    pub fn dimensions(&self, rank: usize) -> [usize; 2] {
        if self.name.ends_with(LORA_A) {
            [self.fixed, rank]
        } else {
            [rank, self.fixed]
        }
    }
}

/// The inputs a model takes beyond `input_ids` and `attention_mask`.
#[derive(Clone, Debug, PartialEq, Eq)]
struct Inputs {
    position_ids: bool,
    beam_idx: bool,
    /// The adapter inputs' matrices, when the model has them.
    adapter: Vec<AdapterInput>,
    /// Whether it takes the adapter's scale as an input ([`ADAPTER_SCALE`]) rather than folded
    /// into B.
    scale: bool,
}

/// The compiled model, and the reply under way.
pub struct OpenVinoModel {
    // The requests go before the compiled model they came from, and that before the core.
    reply: Option<ReplyState>,
    /// The NPU's one request, kept between replies.
    npu_request: Option<InferRequest>,
    compiled: CompiledModel,
    inputs: Inputs,
    /// What a reply without an adapter binds to the adapter inputs, when the model has them.
    no_adapter: Option<Adapter>,
    device: String,
    _core: Core,
}

/// The reply being generated: its request, and how many positions its cache holds.
struct ReplyState {
    request: InferRequest,
    length: usize,
}

impl OpenVinoModel {
    /// Reads and compiles the model in `folder` for `options.device`.
    pub fn load(folder: &Path, options: &Options) -> Result<Self, ModelError> {
        runtime::load().map_err(ModelError::Runtime)?;
        let mut core = Core::new().map_err(ModelError::Setup)?;
        let device = options.device.to_ascii_uppercase();
        let started = Instant::now();
        let [xml, bin] = model_files(folder)?;
        let model = core
            .read_model_from_file(&xml, &bin)
            .map_err(call("reading the model"))?;
        let inputs = check_inputs(&model, folder)?;
        let properties = properties(&device, options);
        let properties: Vec<(&str, &str)> = properties
            .iter()
            .map(|(key, value)| (key.as_str(), value.as_str()))
            .collect();
        let mut compiled = core
            .compile_model_with_properties(&model, DeviceType::from(device.as_str()), &properties)
            .map_err(call("compiling the model"))?;
        let no_adapter = if inputs.adapter.is_empty() {
            None
        } else {
            Some(Adapter::none(&inputs.adapter).map_err(call("preparing the model's adapter inputs"))?)
        };
        let npu_request = if device == "NPU" {
            Some(
                compiled
                    .create_infer_request()
                    .map_err(call("starting the language model"))?,
            )
        } else {
            None
        };
        tracing::info!(
            device = %device,
            adapter_inputs = inputs.adapter.len(),
            "Compiled the language model in {} ms",
            started.elapsed().as_millis()
        );
        Ok(Self {
            reply: None,
            npu_request,
            compiled,
            inputs,
            no_adapter,
            device,
            _core: core,
        })
    }

    /// The matrices an adapter binds, one input each; none when the model has no adapter inputs.
    pub fn adapter_inputs(&self) -> &[AdapterInput] {
        &self.inputs.adapter
    }

    /// Whether an adapter's scale is folded into its B matrices, as the model takes no
    /// [`ADAPTER_SCALE`].
    pub fn folds_adapter_scale(&self) -> bool {
        !self.inputs.adapter.is_empty() && !self.inputs.scale
    }

    /// The device it runs on.
    pub fn device(&self) -> &str {
        &self.device
    }

    /// Starts a reply: runs the prompt `ids` from an empty cache, with `adapter`'s branches (made
    /// for this model's [`Self::adapter_inputs`]) or none, and returns the logits of the token
    /// that follows the prompt.
    pub fn prefill(&mut self, ids: &[u32], adapter: Option<&Adapter>) -> Result<Vec<f32>, ModelError> {
        // The last reply's cache goes first, so two are never held at once.
        self.finish();
        if self.device == "NPU" && ids.len() > NPU_PROMPT_TOKENS {
            return Err(ModelError::TooLong {
                tokens: ids.len(),
                limit: NPU_PROMPT_TOKENS,
            });
        }
        let adapter = match (adapter, &self.no_adapter) {
            (Some(adapter), Some(_)) => Some(adapter),
            (None, no_adapter) => no_adapter.as_ref(),
            (Some(adapter), None) => {
                return Err(ModelError::NoAdapterInputs {
                    adapter: adapter.name().to_owned(),
                });
            }
        };
        let mut request = match self.npu_request.take() {
            Some(request) => request,
            None => self
                .compiled
                .create_infer_request()
                .map_err(call("starting the language model"))?,
        };
        if let Some(adapter) = adapter
            && let Err(error) = bind(&mut request, adapter, self.inputs.scale)
        {
            if self.device == "NPU" {
                self.npu_request = Some(request);
            }
            return Err(error);
        }
        let reply = self.reply.insert(ReplyState { request, length: 0 });
        run(reply, ids, &self.inputs)
    }

    /// Continues the reply with `token`, and returns the logits of the token that follows it.
    pub fn step(&mut self, token: u32) -> Result<Vec<f32>, ModelError> {
        let limit = (self.device == "NPU").then_some(NPU_PROMPT_TOKENS + NPU_REPLY_TOKENS);
        let reply = self.reply.as_mut().ok_or(ModelError::NoReply)?;
        if let Some(limit) = limit.filter(|&limit| reply.length >= limit) {
            return Err(ModelError::TooLong {
                tokens: reply.length + 1,
                limit,
            });
        }
        run(reply, &[token], &self.inputs)
    }

    /// Ends the reply under way: its cache is freed, or on the NPU its request kept for the next.
    pub fn finish(&mut self) {
        if let Some(reply) = self.reply.take()
            && self.device == "NPU"
        {
            self.npu_request = Some(reply.request);
        }
    }
}

/// Binds `adapter`'s matrices to the request's adapter inputs for the whole reply, and its scale
/// when the model takes it (`scale_input`).
fn bind(request: &mut InferRequest, adapter: &Adapter, scale_input: bool) -> Result<(), ModelError> {
    for (name, matrix) in adapter.tensors() {
        request
            .set_tensor(name, matrix)
            .map_err(call("setting the adapter's matrices"))?;
    }
    if scale_input {
        let scale =
            tensor(ElementType::F32, &[1], &[adapter.scale()]).map_err(call("preparing the adapter's scale"))?;
        request
            .set_tensor(ADAPTER_SCALE, &scale)
            .map_err(call("setting the adapter's scale"))?;
    }
    Ok(())
}

/// Runs `ids` at the positions after the reply's cache, and returns the last one's logits.
fn run(reply: &mut ReplyState, ids: &[u32], inputs: &Inputs) -> Result<Vec<f32>, ModelError> {
    let first = reply.length;
    let total = first + ids.len();
    let ids: Vec<i64> = ids.iter().map(|&id| i64::from(id)).collect();
    let positions: Vec<i64> = (first..total).map(to_dimension).collect();
    let mut feeds = vec![
        ("input_ids", tensor(ElementType::I64, &[1, ids.len()], &ids)),
        (
            "attention_mask",
            tensor(ElementType::I64, &[1, total], &vec![1_i64; total]),
        ),
    ];
    if inputs.position_ids {
        feeds.push(("position_ids", tensor(ElementType::I64, &[1, ids.len()], &positions)));
    }
    if inputs.beam_idx {
        feeds.push(("beam_idx", tensor(ElementType::I32, &[1], &[0_i32])));
    }
    for (name, feed) in feeds {
        let feed = feed.map_err(call("preparing the language model's input"))?;
        reply
            .request
            .set_tensor(name, &feed)
            .map_err(call("setting the language model's input"))?;
    }
    reply.request.infer().map_err(call("running the language model"))?;
    reply.length = total;
    last_logits(&reply.request)
}

/// The logits of the last position run.
fn last_logits(request: &InferRequest) -> Result<Vec<f32>, ModelError> {
    let tensor = request.get_tensor("logits").map_err(call("reading the logits"))?;
    let shape = tensor
        .get_shape()
        .map_err(call("reading the logits' shape"))?
        .get_dimensions()
        .to_vec();
    let values = tensor.get_data::<f32>().map_err(call("reading the logits"))?;
    let width = match shape.as_slice() {
        [1, positions, width] if *positions > 0 && *width > 0 => usize::try_from(*width).ok(),
        _ => None,
    }
    .ok_or_else(|| ModelError::Output { shape: shape.clone() })?;
    Ok(values[values.len() - width..].to_vec())
}

/// Checks the model takes what this module feeds it, and notes which optional inputs it has.
fn check_inputs(model: &Model, folder: &Path) -> Result<Inputs, ModelError> {
    let problem = |problem: String| ModelError::Folder {
        path: folder.to_owned(),
        problem,
    };
    let count = model.get_inputs_len().map_err(call("reading the model's inputs"))?;
    let mut names = Vec::with_capacity(count);
    let mut adapter = Vec::new();
    for index in 0..count {
        let input = model
            .get_input_by_index(index)
            .map_err(call("reading the model's inputs"))?;
        let name = input.get_name().map_err(call("reading the model's inputs"))?;
        if name.ends_with(LORA_A) || name.ends_with(LORA_B) {
            let element = input.get_element_type().map_err(call("reading the model's inputs"))?;
            let shape = input.get_partial_shape().map_err(call("reading the model's inputs"))?;
            let rank = shape.get_rank();
            let dimensions = if rank.get_min() == 2 && rank.get_max() == 2 {
                shape.get_dimensions()
            } else {
                &[]
            };
            let fixed = match dimensions {
                [fixed, _] if name.ends_with(LORA_A) => Some(fixed),
                [_, fixed] => Some(fixed),
                _ => None,
            }
            .filter(|fixed| !fixed.is_dynamic())
            .and_then(|fixed| usize::try_from(fixed.get_min()).ok())
            .filter(|&fixed| fixed > 0);
            match (fixed, element) {
                (Some(fixed), ElementType::F16 | ElementType::F32) => adapter.push(AdapterInput {
                    name: name.clone(),
                    element,
                    fixed,
                }),
                _ => {
                    return Err(problem(format!(
                        "its adapter input {name} isn't a 16- or 32-bit float matrix of one fixed dimension"
                    )));
                }
            }
        }
        names.push(name);
    }
    let has = |name: &str| names.iter().any(|input| input == name);
    if !has("input_ids") || !has("attention_mask") {
        return Err(problem(format!(
            "its model takes {names:?}, not a stateful language model's input_ids and attention_mask"
        )));
    }
    if let Some(name) = names.iter().find(|name| {
        !matches!(
            name.as_str(),
            "input_ids" | "attention_mask" | "position_ids" | "beam_idx" | ADAPTER_SCALE
        ) && !name.ends_with(LORA_A)
            && !name.ends_with(LORA_B)
    }) {
        return Err(problem(format!(
            "its model takes an input this build doesn't know, {name:?}"
        )));
    }
    // A branch needs both its matrices, and the branches their scale.
    for input in &adapter {
        let pair = match (input.name.strip_suffix(LORA_A), input.name.strip_suffix(LORA_B)) {
            (Some(projection), _) => format!("{projection}{LORA_B}"),
            (_, Some(projection)) => format!("{projection}{LORA_A}"),
            (None, None) => unreachable!("an adapter input's name ends in {LORA_A} or {LORA_B}"),
        };
        if !has(&pair) {
            return Err(problem(format!("its model takes {} without {pair}", input.name)));
        }
    }
    if adapter.is_empty() && has(ADAPTER_SCALE) {
        return Err(problem(format!(
            "its model takes {ADAPTER_SCALE} without adapter matrices"
        )));
    }
    // Without a scale input, the scale is folded into B, exactly only in 32-bit floats.
    if !has(ADAPTER_SCALE)
        && let Some(narrow) = adapter
            .iter()
            .find(|input| input.name.ends_with(LORA_B) && input.element != ElementType::F32)
    {
        return Err(problem(format!(
            "its model takes {} in {:?} and no {ADAPTER_SCALE} to scale it by",
            narrow.name, narrow.element
        )));
    }
    Ok(Inputs {
        position_ids: has("position_ids"),
        beam_idx: has("beam_idx"),
        scale: has(ADAPTER_SCALE),
        adapter,
    })
}

/// The compilation's properties: low latency; on the CPU, the KV cache in 16-bit floats (the Mac's
/// MLX keeps it in 16 bits too; OpenVINO's CPU default is 8-bit); on the NPU, its LLM mode; the
/// cache of compiled models; then `options.properties`, over those.
///
/// They go to the compilation itself rather than to the device (`Core::set_property`): the NPU
/// reads its LLM mode only from there, and the C function that sets a device's properties takes
/// them as variadic arguments, which openvino-sys, linked at run time, calls as fixed ones: that
/// happens to work on x86-64 Linux, and passes garbage on Apple silicon.
fn properties(device: &str, options: &Options) -> Vec<(String, String)> {
    let mut properties: Vec<(String, String)> = Vec::new();
    let mut set = |key: &str, value: String| {
        properties.retain(|(existing, _)| existing != key);
        properties.push((key.to_owned(), value));
    };
    match device {
        "NPU" => {
            set("NPU_USE_NPUW", "YES".to_owned());
            set("NPUW_LLM", "YES".to_owned());
            set("NPUW_LLM_MAX_PROMPT_LEN", NPU_PROMPT_TOKENS.to_string());
            set("NPUW_LLM_MIN_RESPONSE_LEN", NPU_REPLY_TOKENS.to_string());
        }
        "CPU" => {
            set("PERFORMANCE_HINT", "LATENCY".to_owned());
            set("KV_CACHE_PRECISION", "f16".to_owned());
        }
        _ => set("PERFORMANCE_HINT", "LATENCY".to_owned()),
    }
    if let Some(cache) = options.cache.as_deref().and_then(Path::to_str) {
        set("CACHE_DIR", cache.to_owned());
    }
    for (key, value) in &options.properties {
        set(key, value.clone());
    }
    properties
}

/// The model's `.xml` and `.bin` in `folder`.
fn model_files(folder: &Path) -> Result<[String; 2], ModelError> {
    let path = |name: &str| {
        let path = folder.join(name);
        if !path.is_file() {
            return Err(ModelError::Folder {
                path: folder.to_owned(),
                problem: format!("it has no {name}"),
            });
        }
        path.to_str().map(str::to_owned).ok_or_else(|| ModelError::Folder {
            path: folder.to_owned(),
            problem: "its path isn't UTF-8".to_owned(),
        })
    };
    Ok([path(MODEL_XML)?, path(MODEL_BIN)?])
}

/// A tensor of `dimensions` holding `values`.
fn tensor<T: Copy>(element: ElementType, dimensions: &[usize], values: &[T]) -> Result<Tensor, InferenceError> {
    let dimensions: Vec<i64> = dimensions.iter().map(|&dimension| to_dimension(dimension)).collect();
    let mut tensor = Tensor::new(element, &Shape::new(&dimensions)?)?;
    tensor.get_data_mut::<T>()?.copy_from_slice(values);
    Ok(tensor)
}

fn call(doing: &'static str) -> impl Fn(InferenceError) -> ModelError {
    move |source| ModelError::Call { doing, source }
}

fn to_dimension(count: usize) -> i64 {
    i64::try_from(count).expect("a tensor dimension fits in i64")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_cpu_keeps_its_cache_in_16_bits_unless_told_otherwise() {
        let options = Options {
            cache: Some(PathBuf::from("/cache")),
            properties: vec![("KV_CACHE_PRECISION".to_owned(), "u8".to_owned())],
            ..Options::default()
        };
        assert_eq!(
            properties("CPU", &options),
            [
                ("PERFORMANCE_HINT".to_owned(), "LATENCY".to_owned()),
                ("CACHE_DIR".to_owned(), "/cache".to_owned()),
                ("KV_CACHE_PRECISION".to_owned(), "u8".to_owned()),
            ]
        );
    }

    #[test]
    fn the_npu_runs_the_model_in_its_llm_mode() {
        let properties = properties("NPU", &Options::default());
        assert!(properties.contains(&("NPUW_LLM".to_owned(), "YES".to_owned())));
        assert!(properties.iter().all(|(key, _)| key != "KV_CACHE_PRECISION"));
        assert!(properties.len() <= 8, "the vendored compile_model takes eight at most");
    }
}
