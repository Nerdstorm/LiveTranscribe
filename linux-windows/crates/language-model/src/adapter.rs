//! LoRA adapters, for a model exported with adapter inputs (`tools/export-qwen3-cleanup.py`).
//!
//! Each projection such a model adapts computes `W x + scale * (x A) B`, as mlx-swift-lm's
//! `QLoRALinear` computes it on the Mac. A (`….lora_a`, `[in, rank]`) and B (`….lora_b`,
//! `[rank, out]`) are inputs of the model, not weights in it. The scale is folded into B as the
//! adapter loads, in 32-bit floats; or, for a model that takes it as an input (`adapter_scale`),
//! bound with the matrices.
//!
//! An adapter is the Mac's pair of files, as mlx-lm writes them:
//! - `adapters.safetensors`: A and B of each projection, in 16-bit floats;
//! - `adapter_config.json`: the rank, the scale and the base model it was trained on.
//!
//! The runtime holds any number of adapters, each a set of tensors, and binds one of them, or
//! none, request by request. So the model is compiled once, whichever adapter a request asks for.

use std::collections::HashMap;
use std::fmt;
use std::path::{Path, PathBuf};

use openvino::{ElementType, InferenceError, Shape, Tensor};
use serde::Deserialize;

use crate::openvino_model::{AdapterInput, LORA_B};

/// An adapter's matrices, in its folder.
pub const ADAPTER_WEIGHTS: &str = "adapters.safetensors";
/// An adapter's rank, scale and base model, in its folder.
pub const ADAPTER_CONFIG: &str = "adapter_config.json";

/// The largest safetensors header this reads. The format's own limit is 100 MB, and an adapter's
/// header is a few tens of KB.
const MAX_HEADER_BYTES: usize = 100_000_000;

/// An adapter, loaded: its matrices as the model's adapter inputs take them, and its scale.
pub struct Adapter {
    name: String,
    scale: f32,
    rank: usize,
    base: Option<String>,
    /// Each adapter input's tensor, in the model's order.
    tensors: Vec<(String, Tensor)>,
}

impl fmt::Debug for Adapter {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Adapter")
            .field("name", &self.name)
            .field("scale", &self.scale)
            .field("rank", &self.rank)
            .field("base", &self.base)
            .field("tensors", &self.tensors.len())
            .finish()
    }
}

impl Adapter {
    /// The name requests use for it.
    pub fn name(&self) -> &str {
        &self.name
    }

    /// The factor on its branch, from its config: 20 for the Mac's cleanup adapter.
    pub fn scale(&self) -> f32 {
        self.scale
    }

    pub fn rank(&self) -> usize {
        self.rank
    }

    /// The model it was trained on, `repository@revision`, when its config says.
    pub fn base(&self) -> Option<&str> {
        self.base.as_deref()
    }

    pub(crate) fn tensors(&self) -> &[(String, Tensor)] {
        &self.tensors
    }

    /// Reads the adapter in `folder` and prepares its tensors for the model's `inputs`, as
    /// [`Self::from_bytes`] does.
    pub(crate) fn load(
        name: &str,
        folder: &Path,
        inputs: &[AdapterInput],
        fold_scale: bool,
    ) -> Result<Self, AdapterError> {
        let read = |file: &str| {
            let path = folder.join(file);
            std::fs::read(&path).map_err(|error| AdapterError::Read {
                path,
                problem: error.to_string(),
            })
        };
        Self::from_bytes(
            name,
            folder,
            &read(ADAPTER_CONFIG)?,
            &read(ADAPTER_WEIGHTS)?,
            inputs,
            fold_scale,
        )
    }

    /// Prepares the adapter whose `adapter_config.json` and `adapters.safetensors` are `config`
    /// and `weights` for the model's `inputs`, with its scale folded into B when `fold_scale`. It
    /// must have a matrix for each input, of the rank its config gives, and none for anything
    /// else. `origin` is the folder the files are in, or would be, for errors.
    pub(crate) fn from_bytes(
        name: &str,
        origin: &Path,
        config: &[u8],
        weights: &[u8],
        inputs: &[AdapterInput],
        fold_scale: bool,
    ) -> Result<Self, AdapterError> {
        let config: Config = serde_json::from_slice(config).map_err(|error| AdapterError::Read {
            path: origin.join(ADAPTER_CONFIG),
            problem: error.to_string(),
        })?;
        let matrices = plan(&config, weights, inputs, fold_scale).map_err(|problem| AdapterError::Mismatch {
            path: origin.to_owned(),
            problem,
        })?;
        let tensors = matrices
            .iter()
            .map(|matrix| Ok((matrix.name.clone(), matrix.tensor()?)))
            .collect::<Result<_, InferenceError>>()
            .map_err(AdapterError::Tensor)?;
        let base = config.base_model.map(|model| match config.base_revision {
            Some(revision) => format!("{model}@{revision}"),
            None => model,
        });
        Ok(Self {
            name: name.to_owned(),
            scale: config.lora_parameters.scale,
            rank: config.lora_parameters.rank,
            base,
            tensors,
        })
    }

    /// No adapter: a branch of rank 1, all zeros, in each adapted projection, scaled by 0. It
    /// leaves the base model's outputs exactly as they are, at the least cost the inputs allow.
    pub(crate) fn none(inputs: &[AdapterInput]) -> Result<Self, InferenceError> {
        let tensors = inputs
            .iter()
            .map(|input| {
                let matrix = Matrix {
                    name: input.name.clone(),
                    element: input.element,
                    dimensions: input.dimensions(1),
                    values: Values::Zeros,
                    factor: 1.0,
                };
                Ok((matrix.name.clone(), matrix.tensor()?))
            })
            .collect::<Result<_, InferenceError>>()?;
        Ok(Self {
            name: String::new(),
            scale: 0.0,
            rank: 1,
            base: None,
            tensors,
        })
    }
}

/// Why an adapter couldn't be loaded.
#[derive(Debug)]
pub enum AdapterError {
    /// The model has no adapter inputs: it was exported without them.
    NotAdaptable,
    Read {
        path: PathBuf,
        problem: String,
    },
    /// The files aren't an adapter the model can take.
    Mismatch {
        path: PathBuf,
        problem: String,
    },
    /// OpenVINO couldn't make a tensor for it.
    Tensor(InferenceError),
}

impl fmt::Display for AdapterError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NotAdaptable => f.write_str("the language model was exported without adapter inputs"),
            Self::Read { path, problem } => write!(f, "couldn't read {}: {problem}", path.display()),
            Self::Mismatch { path, problem } => {
                write!(f, "{} isn't an adapter this model can take: {problem}", path.display())
            }
            Self::Tensor(error) => write!(f, "OpenVINO failed making the adapter's tensors: {error}"),
        }
    }
}

impl std::error::Error for AdapterError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Tensor(error) => Some(error),
            _ => None,
        }
    }
}

/// `adapter_config.json`, as mlx-lm writes it; what the runtime needs from it.
#[derive(Deserialize)]
struct Config {
    base_model: Option<String>,
    base_revision: Option<String>,
    /// `lora`; mlx-lm's `dora` scales the branch differently, which the model doesn't compute.
    fine_tune_type: Option<String>,
    lora_parameters: LoraParameters,
}

#[derive(Deserialize)]
struct LoraParameters {
    rank: usize,
    scale: f32,
}

/// An adapter input's matrix, checked and ready to become its tensor.
#[derive(Debug, PartialEq)]
struct Matrix<'a> {
    name: String,
    element: ElementType,
    dimensions: [usize; 2],
    values: Values<'a>,
    /// What each value is multiplied by: the adapter's scale for a B it's folded into, else 1.
    factor: f32,
}

#[derive(Debug, PartialEq)]
enum Values<'a> {
    /// 16-bit floats, little-endian, as safetensors stores them.
    F16(&'a [u8]),
    Zeros,
}

impl Matrix<'_> {
    /// The tensor, in the input's element type: 16-bit floats as they are, or widened to 32 and
    /// multiplied by the factor (exactly: an f16 times a small whole number fits in an f32).
    fn tensor(&self) -> Result<Tensor, InferenceError> {
        let dimensions = self
            .dimensions
            .map(|dimension| i64::try_from(dimension).expect("a dimension fits in i64"));
        let mut tensor = Tensor::new(self.element, &Shape::new(&dimensions)?)?;
        match (&self.values, self.element) {
            (Values::Zeros, _) => tensor.get_raw_data_mut()?.fill(0),
            (Values::F16(bytes), ElementType::F32) => {
                let (halves, _) = bytes.as_chunks::<2>();
                for (value, &half) in tensor.get_data_mut::<f32>()?.iter_mut().zip(halves) {
                    *value = f16_to_f32(u16::from_le_bytes(half)) * self.factor;
                }
            }
            // The model's adapter inputs are 16- or 32-bit floats (checked when it loads), and a
            // factor other than 1 only goes to 32-bit ones ([`plan`]).
            (Values::F16(bytes), _) => {
                let (halves, _) = bytes.as_chunks::<2>();
                for (value, &half) in tensor.get_data_mut::<u16>()?.iter_mut().zip(halves) {
                    *value = u16::from_le_bytes(half);
                }
            }
        }
        Ok(tensor)
    }
}

/// Checks the adapter against the model's `inputs` and pairs each input with its matrix, the
/// scale folded into each B when `fold_scale`.
fn plan<'a>(
    config: &Config,
    weights: &'a [u8],
    inputs: &[AdapterInput],
    fold_scale: bool,
) -> Result<Vec<Matrix<'a>>, String> {
    if let Some(kind) = config.fine_tune_type.as_deref().filter(|kind| *kind != "lora") {
        return Err(format!(
            "it's a {kind} adapter, and the model computes LoRA's branch only"
        ));
    }
    let LoraParameters { rank, scale } = config.lora_parameters;
    if rank == 0 || !scale.is_finite() {
        return Err(format!("its config gives rank {rank} and scale {scale}"));
    }
    let mut tensors = safetensors(weights)?;
    let mut matrices = Vec::with_capacity(inputs.len());
    for input in inputs {
        let tensor = tensors
            .remove(&input.name)
            .ok_or_else(|| format!("it has no {}", input.name))?;
        if tensor.dtype != "F16" {
            return Err(format!("{} is {}, not 16-bit floats (F16)", input.name, tensor.dtype));
        }
        let expected = input.dimensions(rank);
        if tensor.shape != expected {
            return Err(format!(
                "{} is {:?}, and the model takes {expected:?} at rank {rank}",
                input.name, tensor.shape
            ));
        }
        let factor = if fold_scale && input.name.ends_with(LORA_B) {
            if input.element != ElementType::F32 {
                return Err(format!(
                    "the scale is folded into {}, which must then take 32-bit floats, not {:?}",
                    input.name, input.element
                ));
            }
            scale
        } else {
            1.0
        };
        matrices.push(Matrix {
            name: input.name.clone(),
            element: input.element,
            dimensions: expected,
            values: Values::F16(tensor.data),
            factor,
        });
    }
    if let Some(name) = tensors.keys().min() {
        return Err(format!("it adapts {name}, which the model has no input for"));
    }
    Ok(matrices)
}

/// A tensor in a safetensors file.
#[derive(Debug)]
struct Stored<'a> {
    dtype: String,
    shape: Vec<usize>,
    data: &'a [u8],
}

/// The tensors in a safetensors file, by name: an 8-byte little-endian header length, a JSON
/// header of each tensor's type, shape and byte range, then the data those ranges index.
fn safetensors(bytes: &[u8]) -> Result<HashMap<String, Stored<'_>>, String> {
    #[derive(Deserialize)]
    struct Entry {
        dtype: String,
        shape: Vec<usize>,
        data_offsets: [usize; 2],
    }
    let (length, rest) = bytes
        .split_first_chunk::<8>()
        .ok_or("its weights file is too short for a safetensors header")?;
    let length = usize::try_from(u64::from_le_bytes(*length))
        .ok()
        .filter(|&length| length <= rest.len() && length <= MAX_HEADER_BYTES)
        .ok_or("its weights file's header runs past its end")?;
    let (header, data) = rest.split_at(length);
    let mut header: HashMap<String, serde_json::Value> =
        serde_json::from_slice(header).map_err(|error| format!("its weights file's header: {error}"))?;
    header.remove("__metadata__");
    let mut tensors = HashMap::with_capacity(header.len());
    for (name, entry) in header {
        let entry: Entry =
            serde_json::from_value(entry).map_err(|error| format!("its weights file's {name}: {error}"))?;
        let [begin, end] = entry.data_offsets;
        // The bytes its type and shape take, for a type this knows.
        let size = element_bytes(&entry.dtype).map(|bytes| {
            entry
                .shape
                .iter()
                .try_fold(bytes, |size, &dimension| size.checked_mul(dimension))
        });
        if begin > end || end > data.len() || size.is_some_and(|size| size != Some(end - begin)) {
            return Err(format!(
                "its weights file's {name} ({} {:?}) has bytes {begin}..{end} of {}",
                entry.dtype,
                entry.shape,
                data.len()
            ));
        }
        tensors.insert(
            name,
            Stored {
                dtype: entry.dtype,
                shape: entry.shape,
                data: &data[begin..end],
            },
        );
    }
    Ok(tensors)
}

/// The bytes an element of a safetensors type takes, for the types an adapter might hold.
fn element_bytes(dtype: &str) -> Option<usize> {
    match dtype {
        "F64" | "I64" | "U64" => Some(8),
        "F32" | "I32" | "U32" => Some(4),
        "F16" | "BF16" | "I16" | "U16" => Some(2),
        "I8" | "U8" | "BOOL" => Some(1),
        _ => None,
    }
}

/// An IEEE 754 half-precision float, widened exactly.
fn f16_to_f32(bits: u16) -> f32 {
    let sign = u32::from(bits >> 15) << 31;
    let exponent = u32::from((bits >> 10) & 0x1f);
    let fraction = u32::from(bits & 0x3ff);
    match exponent {
        // Zero, or subnormal: the fraction in units of 2^-24, which f32 holds exactly.
        0 => {
            let magnitude = f32::from(bits & 0x3ff) / 16_777_216.0;
            if sign == 0 { magnitude } else { -magnitude }
        }
        0x1f => f32::from_bits(sign | 0x7f80_0000 | (fraction << 13)),
        _ => f32::from_bits(sign | ((exponent + 112) << 23) | (fraction << 13)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn input(name: &str, fixed: usize) -> AdapterInput {
        AdapterInput {
            name: name.to_owned(),
            element: ElementType::F16,
            fixed,
        }
    }

    const A: &str = "model.layers.0.mlp.up_proj.lora_a";
    const B: &str = "model.layers.0.mlp.up_proj.lora_b";

    /// A safetensors file of `tensors` (name, dtype, shape, bytes), in that order.
    fn file(tensors: &[(&str, &str, &[usize], Vec<u8>)]) -> Vec<u8> {
        let mut header = serde_json::Map::new();
        header.insert("__metadata__".to_owned(), serde_json::json!({"format": "mlx"}));
        let mut data = Vec::new();
        for (name, dtype, shape, bytes) in tensors {
            header.insert(
                (*name).to_owned(),
                serde_json::json!({"dtype": dtype, "shape": shape, "data_offsets": [data.len(), data.len() + bytes.len()]}),
            );
            data.extend_from_slice(bytes);
        }
        let header = serde_json::to_vec(&header).unwrap();
        let mut file = (header.len() as u64).to_le_bytes().to_vec();
        file.extend(header);
        file.extend(data);
        file
    }

    fn config(rank: usize, kind: Option<&str>) -> Config {
        Config {
            base_model: Some("mlx-community/Qwen3-1.7B-4bit".to_owned()),
            base_revision: None,
            fine_tune_type: kind.map(str::to_owned),
            lora_parameters: LoraParameters { rank, scale: 20.0 },
        }
    }

    fn halves(count: usize) -> Vec<u8> {
        (0..count)
            .flat_map(|index| (0x3c00_u16 + index as u16).to_le_bytes())
            .collect()
    }

    #[test]
    fn widens_half_precision_exactly() {
        assert_eq!(f16_to_f32(0x3c00), 1.0);
        assert_eq!(f16_to_f32(0xc000), -2.0);
        assert_eq!(f16_to_f32(0x7bff), 65_504.0);
        assert_eq!(f16_to_f32(0x3555), 0.333_251_95);
        assert_eq!(f16_to_f32(0x0001), 2.0_f32.powi(-24));
        assert_eq!(f16_to_f32(0x03ff), 1_023.0 * 2.0_f32.powi(-24));
        assert_eq!(f16_to_f32(0x0400), 2.0_f32.powi(-14));
        assert!(f16_to_f32(0x8000) == 0.0 && f16_to_f32(0x8000).is_sign_negative());
        assert_eq!(f16_to_f32(0x7c00), f32::INFINITY);
        assert_eq!(f16_to_f32(0xfc00), f32::NEG_INFINITY);
        assert!(f16_to_f32(0x7e00).is_nan());
    }

    #[test]
    fn reads_a_safetensors_file() {
        let bytes = file(&[(A, "F16", &[3, 2], halves(6)), (B, "F32", &[1], vec![0, 0, 128, 63])]);
        let tensors = safetensors(&bytes).unwrap();
        assert_eq!(tensors.len(), 2);
        assert_eq!(tensors[A].shape, [3, 2]);
        assert_eq!(tensors[A].data, halves(6).as_slice());
        assert_eq!(tensors[B].data, [0, 0, 128, 63]);
    }

    #[test]
    fn refuses_a_damaged_safetensors_file() {
        let good = file(&[(A, "F16", &[3, 2], halves(6))]);
        assert!(safetensors(&good[..good.len() - 1]).is_err(), "data cut short");
        assert!(safetensors(&good[..20]).is_err(), "header cut short");
        assert!(safetensors(&good[..4]).is_err(), "no header length");
        let wrong_size = file(&[(A, "F16", &[3, 3], halves(6))]);
        assert!(safetensors(&wrong_size).is_err(), "shape and bytes disagree");
    }

    #[test]
    fn pairs_each_input_with_its_matrix() {
        let bytes = file(&[(A, "F16", &[4, 2], halves(8)), (B, "F16", &[2, 3], halves(6))]);
        let inputs = [input(A, 4), input(B, 3)];
        let matrices = plan(&config(2, Some("lora")), &bytes, &inputs, false).unwrap();
        assert_eq!(matrices.len(), 2);
        assert!(matrices.iter().all(|matrix| matrix.factor == 1.0));
        assert_eq!((matrices[0].name.as_str(), matrices[0].dimensions), (A, [4, 2]));
        assert_eq!((matrices[1].name.as_str(), matrices[1].dimensions), (B, [2, 3]));
        assert_eq!(matrices[1].values, Values::F16(&bytes[bytes.len() - 12..]));
    }

    #[test]
    fn refuses_an_adapter_the_model_cant_take() {
        let inputs = [input(A, 4), input(B, 3)];
        let good = [
            (A, "F16", &[4_usize, 2][..], halves(8)),
            (B, "F16", &[2, 3][..], halves(6)),
        ];
        let refused = |tensors: &[(&str, &str, &[usize], Vec<u8>)], config: Config| {
            plan(&config, &file(tensors), &inputs, false).expect_err("refused")
        };
        assert!(refused(&good[..1], config(2, None)).contains("has no"));
        let extra = [
            good[0].clone(),
            good[1].clone(),
            ("model.layers.1.mlp.up_proj.lora_a", "F16", &[4, 2], halves(8)),
        ];
        assert!(refused(&extra, config(2, None)).contains("no input for"));
        assert!(refused(&good, config(3, None)).contains("at rank 3"));
        let wide = [(A, "F32", &[4_usize, 2][..], vec![0; 32]), good[1].clone()];
        assert!(refused(&wide, config(2, None)).contains("not 16-bit"));
        assert!(refused(&good, config(2, Some("dora"))).contains("dora"));
        let columns = [input(A, 5), input(B, 3)];
        assert!(
            plan(&config(2, None), &file(&good), &columns, false).is_err(),
            "the projection's width"
        );
    }

    #[test]
    fn an_adapter_from_bytes_is_refused_by_the_folder_it_came_from() {
        let origin = Path::new("Packages/LiveTranscribeKit/Sources/Cleanup/DeepAdapter");
        let inputs = [input(A, 4), input(B, 3)];
        let weights = file(&[(A, "F16", &[4, 2], halves(8)), (B, "F16", &[2, 3], halves(6))]);
        let unreadable = Adapter::from_bytes("deep", origin, b"{", &weights, &inputs, false);
        assert!(matches!(unreadable, Err(AdapterError::Read { path, .. }) if path == origin.join(ADAPTER_CONFIG)));
        let config = br#"{"lora_parameters": {"rank": 3, "scale": 20.0}}"#;
        let mismatched = Adapter::from_bytes("deep", origin, config, &weights, &inputs, false);
        assert!(
            matches!(mismatched, Err(AdapterError::Mismatch { path, problem }) if path == origin && problem.contains("at rank 3"))
        );
    }

    #[test]
    fn folds_the_scale_into_b_in_32_bits() {
        let bytes = file(&[(A, "F16", &[4, 2], halves(8)), (B, "F16", &[2, 3], halves(6))]);
        let wide = |name: &str, fixed| AdapterInput {
            element: ElementType::F32,
            ..input(name, fixed)
        };
        let matrices = plan(&config(2, None), &bytes, &[wide(A, 4), wide(B, 3)], true).unwrap();
        assert_eq!((matrices[0].factor, matrices[1].factor), (1.0, 20.0));
        // Folded into a 16-bit B, the scale would be rounded: refused.
        let narrow_b = plan(&config(2, None), &bytes, &[wide(A, 4), input(B, 3)], true);
        assert!(narrow_b.expect_err("refused").contains("32-bit"));
    }
}
