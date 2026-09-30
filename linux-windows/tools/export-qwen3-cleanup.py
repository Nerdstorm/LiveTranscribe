#!/usr/bin/env python3
"""Converts the Mac's cleanup model, with its self-correction adapter, to the OpenVINO model the
Linux and Windows app runs (crates/language-model).

The Mac runs mlx-community/Qwen3-1.7B-4bit at 3b1b176 through mlx-swift-lm, with the LoRA adapter
in Packages/LiveTranscribeKit/Sources/Cleanup/Adapter loaded beside its weights and switched on per
request (Medium and High) or off (LiveTranscribe-0027, -0041). This script starts from OpenVINO's
published conversion of Qwen3-1.7B, OpenVINO/Qwen3-1.7B-int4-ov at 6f32d81, whose graph
(optimum-intel's stateful export: input_ids, attention_mask, position_ids and beam_idx in, logits
out, the KV cache as state) it keeps, and changes three things:

  weights  --weights mlx (the default) puts the Mac's weights in every projection, the embeddings
           and the output layer: MLX's affine 4-bit groups of 64 are written as they are, as
           OpenVINO's u4 weights with a u4 zero point and an f16 scale a group, the pattern NNCF
           writes, which the CPU plugin runs as compressed weights. MLX makes each group's bias a
           whole number of steps (its edge divided by a rounded step), so -bias / scale is a whole
           zero point to within 5% of a step, and the weights are the Mac's. Requantising the
           dequantised weights with NNCF instead (INT4_ASYM, group 64) would move 42% of them, by
           up to half a step. --weights published keeps OpenVINO's (Qwen/Qwen3-1.7B in bf16,
           compressed by NNCF: INT4_ASYM, group 128, ratio 0.8, the rest INT8_ASYM).
  adapter  In each projection the Mac's adapters adapt (q, k, v, o, gate, up and down in the last
           16 layers) a low-rank branch is added to the projection's output,
               y = W x + (x A) B',
           which is mlx-swift-lm 3.31.4's QLoRALinear, y = W x + scale * (x A) B, with the
           adapter's scale (20) folded into B' = scale * B by the runtime (A = lora_a [in, rank],
           B = lora_b [rank, out]). A and B' are inputs of the model, in 32-bit floats and of any
           rank, named as the adapter's tensors (model.layers.12.self_attn.q_proj.lora_a, ...):
           the runtime binds one adapter's, the Medium one or another trained the same way, request
           by request, or zeros for the base model. So adapters stay separate files, one model
           serves them all, and nothing quantises them or folds them into the 4-bit weights, which
           rounded the adapter away on the Mac. --scale-input takes A and B in 16-bit floats and
           the scale as an input of its own (adapter_scale, [1]), which costs a Convert of each
           matrix and a Multiply more a projection, every pass. --no-adapter leaves the branches
           out.
  logits   Only the last position's logits are computed (a Gather before the output layer): the
           runtime reads no others, and the published model computes the vocabulary's logits for
           every prompt position. --all-logits keeps them all.

Each converted model is checked against PyTorch: transformers' Qwen3ForCausalLM with the same
weights (dequantised from the converted model itself) and the adapter applied as mlx-swift-lm
applies it, on cleanup prompts, with the adapter off and on: the next token's logits, and greedy
replies. With --weights mlx, the converted weights are also compared with MLX's dequantisation.

Run it in a Python environment with openvino, torch, transformers, safetensors and
huggingface_hub:

    python export-qwen3-cleanup.py --out models/qwen3-1.7b-cleanup-ov

The published model and the MLX model come from the Hugging Face cache (downloaded at their pinned
commits if they aren't there), or from --base-ir and --mlx folders.
"""

import argparse
import hashlib
import json
import logging
import shutil
import sys
import time
from pathlib import Path

import numpy as np
import openvino as ov
import openvino.opset13 as ops

LOG = logging.getLogger("export-qwen3-cleanup")

# The published model whose graph is kept, and the checksums of its model files at that commit.
BASE_IR = ("OpenVINO/Qwen3-1.7B-int4-ov", "6f32d81e9deebeca30bb5490a7176cf4fa8c79e3")
BASE_IR_SHA256 = {
    "openvino_model.xml": "8d5e2cd13e046009835c488c2005d8f477ae8a0302e3e999cbd430ba0af9af19",
    "openvino_model.bin": "2f15d719cab2e475444ff84d77d432ecf757e0ec5b93dc1b48710802f96ef34f",
}
# The Mac's base model, which the adapter was trained on.
MLX_BASE = ("mlx-community/Qwen3-1.7B-4bit", "3b1b1768f8f8cf8351c712464f906e86c2b8269e")
# What the runtime reads besides the model, copied from the published model's folder.
COPIED_FILES = ["config.json", "generation_config.json", "tokenizer_config.json", "vocab.json", "merges.txt"]
ADAPTER_FOLDER = Path(__file__).resolve().parents[2] / "Packages/LiveTranscribeKit/Sources/Cleanup/Adapter"
ADAPTER_SCALE = "adapter_scale"
# <|im_end|> and <|endoftext|>.
END_OF_REPLY = [151645, 151643]
PROJECTIONS = {
    "q_proj": "self_attn",
    "k_proj": "self_attn",
    "v_proj": "self_attn",
    "o_proj": "self_attn",
    "gate_proj": "mlp",
    "up_proj": "mlp",
    "down_proj": "mlp",
}
EMBEDDING = "__module.model.embed_tokens/ov_ext::embedding/Gather"
LM_HEAD = "__module.lm_head/ov_ext::linear/MatMul"
# How far MLX's -bias / scale may be from a whole zero point, in steps.
ZERO_POINT_TOLERANCE = 0.05
# The checks' prompts: the Medium prompt the adapter was trained on (Prompt.adapted), with
# self-corrections to resolve and a sentence to leave alone.
MEDIUM_ADAPTED = "\n".join(
    [
        "Correct transcription errors, punctuation, casing and grammar in the TEXT.",
        "Preserve meaning, tone, hedging and filler intent exactly.",
        "Do not add, summarise or rephrase content.",
        "When the speaker corrects themselves, keep only the correction.",
        "If the text is already correct, return it unchanged.",
        "Output only the corrected text.",
    ]
)
CHECK_TEXTS = [
    "we need three sorry four servers",
    "can you move my physio appointment to friday sorry thursday",
    "sorry I'm late the train was cancelled",
]


def matmul_name(layer, projection):
    return f"__module.model.layers.{layer}.{PROJECTIONS[projection]}.{projection}/ov_ext::linear/MatMul"


# MARK: - Sources


def snapshot(repository, revision, patterns, folder):
    """A model's folder: `folder` if given, else its snapshot at `revision` in the Hugging Face cache,
    downloaded if it isn't there."""
    if folder:
        return Path(folder)
    from huggingface_hub import snapshot_download

    return Path(snapshot_download(repository, revision=revision, allow_patterns=patterns))


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as file:
        for block in iter(lambda: file.read(1 << 24), b""):
            digest.update(block)
    return digest.hexdigest()


def check_base_ir(folder):
    for name, expected in BASE_IR_SHA256.items():
        found = sha256(folder / name)
        if found != expected:
            sys.exit(f"{folder / name} isn't {BASE_IR[0]}@{BASE_IR[1][:7]}'s (SHA-256 {found})")


def read_adapter(folder, layers):
    """The adapter's A and B of each projection, by (layer, projection), as float16 arrays, after
    checking it was trained on MLX_BASE and adapts what this script adapts."""
    from safetensors import safe_open

    config = json.loads((folder / "adapter_config.json").read_text())
    if (config.get("base_model"), config.get("base_revision")) != MLX_BASE:
        sys.exit(f"the adapter was trained on {config.get('base_model')}@{config.get('base_revision')}, not {MLX_BASE}")
    parameters = config["lora_parameters"]
    adapted = range(layers - config["num_layers"], layers)
    weights = {}
    with safe_open(folder / "adapters.safetensors", "np") as file:
        keys = set(file.keys())
        for layer in adapted:
            for projection, block in PROJECTIONS.items():
                prefix = f"model.layers.{layer}.{block}.{projection}"
                a, b = file.get_tensor(f"{prefix}.lora_a"), file.get_tensor(f"{prefix}.lora_b")
                if a.shape[1] != parameters["rank"] or b.shape[0] != parameters["rank"]:
                    sys.exit(f"{prefix} has rank {a.shape[1]}, not {parameters['rank']}")
                weights[(layer, projection)] = (a.astype(np.float16), b.astype(np.float16))
                keys -= {f"{prefix}.lora_a", f"{prefix}.lora_b"}
    if keys:
        sys.exit(f"the adapter has weights this script doesn't place: {sorted(keys)[:4]}")
    LOG.info("Adapter: rank %d, scale %s, layers %d-%d", parameters["rank"], parameters["scale"], adapted[0], adapted[-1])
    return weights, float(parameters["scale"]), adapted


class MlxWeights:
    """mlx-community's 4-bit checkpoint: each quantised matrix's packed levels (uint32, eight
    4-bit levels each, the first in the lowest bits) and its bfloat16 scales and biases, a group of
    64 each."""

    def __init__(self, folder):
        from safetensors import safe_open

        config = json.loads((folder / "config.json").read_text())
        self.group_size = config["quantization"]["group_size"]
        if config["quantization"]["bits"] != 4:
            sys.exit(f"{folder} isn't 4-bit")
        self.levels = safe_open(folder / "model.safetensors", "np")
        self.floats = safe_open(folder / "model.safetensors", "pt")

    def matrix(self, name):
        """Levels [out, in] as packed u4 bytes [out, groups, group/2], the whole zero points
        [out, groups] and float32 scales [out, groups]."""
        packed = self.levels.get_tensor(f"{name}.weight")
        scales = self.floats.get_tensor(f"{name}.scales").float().numpy()
        biases = self.floats.get_tensor(f"{name}.biases").float().numpy()
        rows, groups = scales.shape
        zero_points = -biases / scales
        whole = np.round(zero_points)
        worst = float(np.abs(zero_points - whole).max())
        if worst > ZERO_POINT_TOLERANCE or whole.min() < 0 or whole.max() > 15:
            sys.exit(f"{name}: MLX's biases aren't whole zero points (off by up to {worst:.3f} steps)")
        levels = packed.view(np.uint8).reshape(rows, groups, self.group_size // 2)
        return levels, whole.astype(np.uint8), scales

    def dequantised(self, name):
        """The matrix as MLX computes it: scale * level + bias, float32."""
        packed = self.levels.get_tensor(f"{name}.weight").view(np.uint32)
        shifts = np.arange(8, dtype=np.uint32) * 4
        levels = ((packed[..., None] >> shifts) & 0xF).astype(np.float32).reshape(packed.shape[0], -1)
        scales = self.floats.get_tensor(f"{name}.scales").float().numpy()
        biases = self.floats.get_tensor(f"{name}.biases").float().numpy()
        rows, groups = scales.shape
        grouped = levels.reshape(rows, groups, -1) * scales[..., None] + biases[..., None]
        return grouped.reshape(rows, -1)

    def norm(self, name):
        return self.floats.get_tensor(f"{name}.weight").float().numpy()


# MARK: - The graph


def nodes_by_name(model):
    return {node.get_friendly_name(): node for node in model.get_ordered_ops()}


def u4_matrix(levels, zero_points, scales, name):
    """The decompression NNCF writes for a group-wise u4 matrix, ending in float32 [out, in]:
    (level - zero point) * scale, a group at a time."""
    rows, groups, half = levels.shape
    weights = ov.Tensor(ov.Type.u4, ov.Shape([rows, groups, half * 2]))
    weights.data[:] = levels.reshape(-1)
    points = ov.Tensor(ov.Type.u4, ov.Shape([rows, groups, 1]))
    flat = zero_points.reshape(-1)
    if flat.size % 2:
        flat = np.append(flat, 0)
    points.data[:] = (flat[0::2] | (flat[1::2] << 4)).astype(np.uint8)
    level = ops.convert(ops.constant(weights, name=f"{name}/levels"), ov.Type.f16)
    point = ops.convert(ops.constant(points, name=f"{name}/zero_points"), ov.Type.f16)
    scale = ops.constant(scales.astype(np.float16)[..., None], name=f"{name}/scales")
    matrix = ops.multiply(ops.subtract(level, point), scale)
    shape = ops.constant(np.array([rows, groups * half * 2], dtype=np.int64))
    return ops.convert(ops.reshape(matrix, shape, special_zero=False), ov.Type.f32, name=f"{name}/weights")


def put_mlx_weights(model, mlx, layers):
    """Replaces each projection's, the embeddings' and the output layer's weights with MLX's."""
    nodes = nodes_by_name(model)
    for layer in range(layers):
        for projection, block in PROJECTIONS.items():
            name = f"model.layers.{layer}.{block}.{projection}"
            matmul = nodes[matmul_name(layer, projection)]
            matmul.input(1).replace_source_output(u4_matrix(*mlx.matrix(name), name).output(0))
    # MLX ties the output layer to the embeddings: both are the one 4-bit matrix.
    embedding = mlx.matrix("model.embed_tokens")
    nodes[EMBEDDING].input(0).replace_source_output(u4_matrix(*embedding, "model.embed_tokens").output(0))
    nodes[LM_HEAD].input(1).replace_source_output(u4_matrix(*embedding, "lm_head").output(0))


def add_adapter_inputs(model, layers, scale_input):
    """Adds to each projection of `layers` a low-rank branch whose matrices are inputs of the
    model: 32-bit floats, B with the adapter's scale folded in by the runtime; or, with
    `scale_input`, 16-bit floats and the scale an input of its own, which costs a Convert of each
    matrix and a Multiply more a projection, every pass. Returns the inputs' names."""
    nodes = nodes_by_name(model)
    element = ov.Type.f16 if scale_input else ov.Type.f32
    parameters = []
    if scale_input:
        switch = ops.parameter(ov.PartialShape([1]), ov.Type.f32, name=ADAPTER_SCALE)
        switch.output(0).get_tensor().set_names({ADAPTER_SCALE})
        parameters.append(switch)
    for layer in layers:
        for projection, block in PROJECTIONS.items():
            prefix = f"model.layers.{layer}.{block}.{projection}"
            matmul = nodes[matmul_name(layer, projection)]
            rows, columns = matmul.input_value(1).get_partial_shape().to_shape()  # [out, in]
            a = ops.parameter(ov.PartialShape([columns, -1]), element, name=f"{prefix}.lora_a")
            b = ops.parameter(ov.PartialShape([-1, rows]), element, name=f"{prefix}.lora_b")
            for parameter in (a, b):
                parameter.output(0).get_tensor().set_names({parameter.get_friendly_name()})
            targets = list(matmul.output(0).get_target_inputs())
            if scale_input:
                down = ops.matmul(matmul.input_value(0), ops.convert(a, ov.Type.f32), False, False)
                branch = ops.multiply(ops.matmul(down, ops.convert(b, ov.Type.f32), False, False), switch)
            else:
                branch = ops.matmul(ops.matmul(matmul.input_value(0), a, False, False), b, False, False)
            output = ops.add(matmul.output(0), branch, name=f"{prefix}.adapter/add")
            for target in targets:
                target.replace_source_output(output.output(0))
            parameters += [a, b]
    model.add_parameters(parameters)
    return [parameter.get_friendly_name() for parameter in parameters]


def keep_last_logits(model):
    """Computes the output layer for the last position only: logits [batch, 1, vocab]."""
    head = nodes_by_name(model)[LM_HEAD]
    last = ops.gather(head.input_value(0), ops.constant(np.array([-1], dtype=np.int64)), ops.constant(np.int64(1)))
    head.input(0).replace_source_output(last.output(0))


# MARK: - Checks


class OpenVinoChat:
    """The converted model on the CPU, run as the Rust runtime runs it."""

    def __init__(self, folder):
        core = ov.Core()
        self.compiled = core.compile_model(
            core.read_model(folder / "openvino_model.xml"),
            "CPU",
            {"INFERENCE_PRECISION_HINT": "f32", "KV_CACHE_PRECISION": "f32", "DYNAMIC_QUANTIZATION_GROUP_SIZE": "0"},
        )
        self.inputs = {port.get_any_name() for port in self.compiled.inputs}

    def logits(self, ids, adapter, scale, steps=0):
        """The next token's logits after `ids`, then after each of `steps` greedy tokens, with
        `adapter`'s tensors bound and its branch scaled by `scale`; and the greedy tokens."""
        request = self.compiled.create_infer_request()
        for (layer, projection), (a, b) in adapter.items():
            prefix = f"model.layers.{layer}.{PROJECTIONS[projection]}.{projection}"
            if ADAPTER_SCALE not in self.inputs:
                # As the runtime binds them: in 32 bits, the scale folded into B.
                a, b = a.astype(np.float32), b.astype(np.float32) * np.float32(scale)
            request.set_tensor(f"{prefix}.lora_a", ov.Tensor(np.ascontiguousarray(a)))
            request.set_tensor(f"{prefix}.lora_b", ov.Tensor(np.ascontiguousarray(b)))
        length, feed, found, tokens = 0, list(ids), [], []
        for _ in range(steps + 1):
            inputs = {
                "input_ids": np.array([feed], dtype=np.int64),
                "attention_mask": np.ones((1, length + len(feed)), dtype=np.int64),
                "position_ids": np.arange(length, length + len(feed), dtype=np.int64)[None],
                "beam_idx": np.zeros(1, dtype=np.int32),
            }
            if ADAPTER_SCALE in self.inputs:
                inputs[ADAPTER_SCALE] = np.array([scale], dtype=np.float32)
            logits = request.infer(inputs)["logits"][0, -1].copy()
            length += len(feed)
            found.append(logits)
            token = int(np.argmax(logits))
            tokens.append(token)
            feed = [token]
        return found, tokens


def weight_arrays(model):
    """Each matrix of the converted model, dequantised by OpenVINO itself: projections, embeddings
    and output layer, by transformers' names."""
    nodes = nodes_by_name(model)
    wanted = {"model.embed_tokens.weight": nodes[EMBEDDING].input_value(0), "lm_head.weight": nodes[LM_HEAD].input_value(1)}
    for name, node in nodes.items():
        if name.startswith("__module.model.layers.") and name.endswith("/ov_ext::linear/MatMul"):
            wanted[name.removeprefix("__module.").split("/")[0] + ".weight"] = node.input_value(1)
    core = ov.Core()
    for name, output in wanted.items():
        constant_model = ov.Model([ops.result(output)], [], name)
        yield name, next(iter(core.compile_model(constant_model, "CPU", {"INFERENCE_PRECISION_HINT": "f32"})({}).values()))


def torch_model(config_path, weights, mlx, adapter):
    """transformers' Qwen3ForCausalLM with `weights`, MLX's norms, and hooks that add the adapter's
    branch, times the scale `set_scale` sets, as mlx-swift-lm's QLoRALinear does."""
    import torch
    from transformers import Qwen3Config, Qwen3ForCausalLM

    config = Qwen3Config.from_pretrained(config_path)
    config.tie_word_embeddings = False
    model = Qwen3ForCausalLM(config).float().eval()
    state = model.state_dict()
    for name in state:
        if name.endswith("norm.weight"):
            state[name] = torch.from_numpy(mlx.norm(name.removesuffix(".weight")))
    for name, array in weights:
        state[name] = torch.from_numpy(np.ascontiguousarray(array, dtype=np.float32))
    model.load_state_dict(state, strict=True)
    factor = {"value": 0.0}
    for (layer, projection), (a, b) in adapter.items():
        module = getattr(getattr(model.model.layers[layer], PROJECTIONS[projection]), projection)
        a32, b32 = torch.from_numpy(a.astype(np.float32)), torch.from_numpy(b.astype(np.float32))

        def hook(_module, inputs, output, a32=a32, b32=b32):
            return output + factor["value"] * ((inputs[0] @ a32) @ b32)

        module.register_forward_hook(hook)

    def set_scale(value):
        factor["value"] = value

    return model, set_scale


def until_end(tokens):
    """A reply's tokens before the first that ends it (<|im_end|> or <|endoftext|>)."""
    ends = [index for index, token in enumerate(tokens) if token in END_OF_REPLY]
    return tokens[: ends[0]] if ends else tokens


def check(folder, config_path, mlx, adapter, scale, weights_kind, replies):
    import torch
    from transformers import AutoTokenizer

    report = {}
    model = ov.Core().read_model(folder / "openvino_model.xml")
    if weights_kind == "mlx":
        worst = 0.0
        for name, array in weight_arrays(model):
            source = "model.embed_tokens" if name == "lm_head.weight" else name.removesuffix(".weight")
            reference = mlx.dequantised(source)
            scales = np.abs(mlx.floats.get_tensor(f"{source}.scales").float().numpy())
            steps = np.abs(array - reference).reshape(scales.shape[0], scales.shape[1], -1) / scales[..., None]
            worst = max(worst, float(steps.max()))
        LOG.info("The converted weights are MLX's to within %.3f of a step", worst)
        report["mlx_weights_max_error_steps"] = worst
        if worst > ZERO_POINT_TOLERANCE + 1e-3:
            sys.exit("the converted weights aren't MLX's")

    reference, set_scale = torch_model(config_path, weight_arrays(model), mlx, adapter)
    converted = OpenVinoChat(folder)
    tokenizer = AutoTokenizer.from_pretrained(folder)
    cases = []
    for text in CHECK_TEXTS:
        messages = [{"role": "system", "content": MEDIUM_ADAPTED}, {"role": "user", "content": f"TEXT:\n{text}"}]
        ids = tokenizer.apply_chat_template(messages, tokenize=True, add_generation_prompt=True, enable_thinking=False)
        ids = list(ids["input_ids"] if hasattr(ids, "keys") else ids)
        for adapter_on in ([False, True] if adapter else [False]):
            scale_value = scale if adapter_on else 0.0
            set_scale(scale_value)
            found, tokens = converted.logits(ids, adapter, scale_value, steps=replies)
            with torch.no_grad():
                expected = reference(torch.tensor([ids])).logits[0, -1].numpy()
                generated = reference.generate(
                    torch.tensor([ids]), max_new_tokens=replies + 1, do_sample=False, eos_token_id=END_OF_REPLY
                )[0, len(ids):].tolist()
            difference = float(np.abs(found[0] - expected).max())
            spread = float(expected.std())
            same_top = int(np.argmax(found[0])) == int(np.argmax(expected))
            ov_reply = tokenizer.decode(until_end(tokens))
            torch_reply = tokenizer.decode(until_end(generated))
            case = {
                "text": text,
                "adapter": adapter_on,
                "max_logit_difference": round(difference, 4),
                "logit_std": round(spread, 3),
                "same_next_token": same_top,
                "same_reply": ov_reply == torch_reply,
                "openvino_reply": ov_reply,
                "pytorch_reply": torch_reply,
            }
            LOG.info("%s", json.dumps(case))
            cases.append(case)
            if not same_top or difference > 0.05 * spread:
                sys.exit(f"the converted model's logits aren't PyTorch's: {case}")
            if not case["same_reply"]:
                # Greedy replies part at a near tie now and then; the logits above are the check.
                LOG.warning("The greedy replies differ: %s", json.dumps(case))
    report["cases"] = cases
    return report


# MARK: - Main


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--out", type=Path, required=True, help="the folder to write")
    parser.add_argument("--weights", choices=["mlx", "published"], default="mlx")
    parser.add_argument("--no-adapter", action="store_true", help="leave the adapter out")
    parser.add_argument(
        "--scale-input",
        action="store_true",
        help="take the adapter's matrices in 16-bit floats and its scale as an input (slower)",
    )
    parser.add_argument("--all-logits", action="store_true", help="keep every position's logits")
    parser.add_argument("--base-ir", help=f"a folder with {BASE_IR[0]}@{BASE_IR[1][:7]}'s files")
    parser.add_argument("--mlx", help=f"a folder with {MLX_BASE[0]}@{MLX_BASE[1][:7]}'s files")
    parser.add_argument("--adapter", type=Path, default=ADAPTER_FOLDER, help="the adapter's folder")
    parser.add_argument("--no-check", action="store_true", help="skip the checks against PyTorch")
    parser.add_argument("--check-replies", type=int, default=16, help="greedy tokens compared in the checks")
    arguments = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s")
    started = time.time()

    base = snapshot(*BASE_IR, [*BASE_IR_SHA256, *COPIED_FILES], arguments.base_ir)
    check_base_ir(base)
    mlx = MlxWeights(snapshot(*MLX_BASE, ["*.json", "*.safetensors"], arguments.mlx))
    layers = json.loads((base / "config.json").read_text())["num_hidden_layers"]
    adapter, scale, adapted = ({}, 0.0, range(0)) if arguments.no_adapter else read_adapter(arguments.adapter, layers)

    model = ov.Core().read_model(base / "openvino_model.xml")
    if arguments.weights == "mlx":
        put_mlx_weights(model, mlx, layers)
    inputs = add_adapter_inputs(model, adapted, arguments.scale_input) if adapter else []
    if not arguments.all_logits:
        keep_last_logits(model)
    model.validate_nodes_and_infer_types()

    out = arguments.out
    out.mkdir(parents=True, exist_ok=True)
    ov.save_model(model, out / "openvino_model.xml", compress_to_fp16=False)
    for name in COPIED_FILES:
        shutil.copyfile(base / name, out / name)
    if adapter:
        # The Medium adapter goes with the model, where the runtime finds it (adapters/<name>/).
        (out / "adapters" / "medium").mkdir(parents=True, exist_ok=True)
        for name in ["adapters.safetensors", "adapter_config.json"]:
            shutil.copyfile(arguments.adapter / name, out / "adapters" / "medium" / name)
    LOG.info("Wrote %s (%.0f MB)", out, (out / "openvino_model.bin").stat().st_size / 1e6)

    export = {
        "graph": f"{BASE_IR[0]}@{BASE_IR[1]}",
        "weights": f"{MLX_BASE[0]}@{MLX_BASE[1]}" if arguments.weights == "mlx" else f"{BASE_IR[0]}@{BASE_IR[1]}",
        "adapter_inputs": None
        if not adapter
        else {
            "layers": [adapted[0], adapted[-1]],
            "projections": list(PROJECTIONS),
            "matrices": "f16" if arguments.scale_input else "f32",
            "scale": f"the input {ADAPTER_SCALE}" if arguments.scale_input else "folded into lora_b by the runtime",
            "inputs": len(inputs),
        },
        "adapters": {}
        if not adapter
        else {
            "medium": {
                name: sha256(arguments.adapter / name) for name in ["adapters.safetensors", "adapter_config.json"]
            }
        },
        "logits": "all positions" if arguments.all_logits else "last position",
        "openvino": ov.__version__,
    }
    if not arguments.no_check:
        export["checks"] = check(out, base / "config.json", mlx, adapter, scale, arguments.weights, arguments.check_replies)
    (out / "export.json").write_text(json.dumps(export, indent=2, ensure_ascii=False) + "\n")
    LOG.info("Done in %.0f s", time.time() - started)


if __name__ == "__main__":
    main()
