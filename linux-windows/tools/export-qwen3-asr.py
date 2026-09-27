#!/usr/bin/env python3
"""Converts Qwen3-ASR to the OpenVINO models the Linux and Windows app runs.

The app computes the model's input features, its prompt and the decoding itself, as the Mac app's
mlx-audio-swift does (crates/transcription), and asks a runtime only for the model's forward
passes (its SpeechModel trait). This script writes those passes as three OpenVINO models:

  audio-conv     the audio encoder's convolutions and positional embedding, over chunks of mel
                 frames: chunks [n, 128, frames] -> rows [n, rows, d_model]
  audio-encoder  its attention layers and output projection, over one window of rows:
                 rows [1, r, d_model] -> embeddings [1, r, hidden]
  text           the language model, with its KV cache kept as state: token ids, audio rows in
                 place of the placeholders, to the logits of the next token [1, 1, vocab]

The passes are written here in PyTorch as mlx-audio-swift's Qwen3ASR.swift computes them, not
taken from transformers, whose model chunks audio the reference way. The checkpoint's weights
load into them strictly, and each converted model is checked against its PyTorch pass.

Run it with the model tools the setup kit installs, inside the live-transcribe toolbox:

    ~/.local/share/live-transcribe/model-tools/bin/python export-qwen3-asr.py \\
        --model <folder with config.json and model.safetensors> \\
        --out ~/.local/share/live-transcribe/models/qwen3-asr-0.6b
"""

import argparse
import json
import logging
import math
import shutil
import sys
import tempfile
import time
from pathlib import Path

import numpy as np
import torch
import torch.nn.functional as F
from torch import nn

LOG = logging.getLogger("export-qwen3-asr")

# The manifest's format. The app refuses a folder written in any other.
MANIFEST_FORMAT = 1
# What the app reads from the checkpoint besides the models: its languages and its tokenizer.
COPIED_FILES = ["config.json", "vocab.json", "merges.txt", "tokenizer_config.json"]


# MARK: - Audio encoder


def sinusoids(length, channels, max_timescale=10_000.0):
    """Qwen3ASRSinusoidalPE: the sines, then the cosines, of each position times each timescale."""
    increment = math.log(max_timescale) / (channels // 2 - 1)
    inverse_timescales = torch.exp(-increment * torch.arange(channels // 2, dtype=torch.float32))
    scaled = torch.arange(length, dtype=torch.float32)[:, None] * inverse_timescales[None, :]
    return torch.cat([torch.sin(scaled), torch.cos(scaled)], dim=1)


class AudioConvolutions(nn.Module):
    """The encoder's front over chunks of mel frames: three stride-2 convolutions over (band,
    frame), each row's channels and remaining bands flattened and projected, and a sinusoidal
    position added that starts again at 0 in every chunk."""

    def __init__(self, config):
        super().__init__()
        channels = config["downsample_hidden_size"]
        self.conv2d1 = nn.Conv2d(1, channels, 3, stride=2, padding=1)
        self.conv2d2 = nn.Conv2d(channels, channels, 3, stride=2, padding=1)
        self.conv2d3 = nn.Conv2d(channels, channels, 3, stride=2, padding=1)
        bands = config["num_mel_bins"]
        for _ in range(3):
            bands = (bands + 1) // 2
        self.conv_out = nn.Linear(channels * bands, config["d_model"], bias=False)
        self.register_buffer(
            "positions", sinusoids(config["max_source_positions"], config["d_model"]), persistent=False
        )

    def forward(self, chunks):
        x = chunks.unsqueeze(1)  # [n, 1, bands, frames]
        x = F.gelu(self.conv2d1(x))
        x = F.gelu(self.conv2d2(x))
        x = F.gelu(self.conv2d3(x))  # [n, channels, bands, rows]
        # Swift's [n, bands, rows, channels] transposed to [n, rows, channels, bands]: channel by
        # channel, each channel's bands.
        x = self.conv_out(x.permute(0, 3, 1, 2).flatten(2))
        return x + self.positions[: x.shape[1]]


class AudioAttention(nn.Module):
    def __init__(self, width, heads):
        super().__init__()
        self.heads = heads
        self.scale = (width // heads) ** -0.5
        self.q_proj = nn.Linear(width, width)
        self.k_proj = nn.Linear(width, width)
        self.v_proj = nn.Linear(width, width)
        self.out_proj = nn.Linear(width, width)

    def forward(self, x):
        q, k, v = (
            projection(x).unflatten(-1, (self.heads, -1)).transpose(1, 2)
            for projection in (self.q_proj, self.k_proj, self.v_proj)
        )
        attended = F.scaled_dot_product_attention(q, k, v, scale=self.scale)
        return self.out_proj(attended.transpose(1, 2).flatten(2))


class AudioEncoderLayer(nn.Module):
    def __init__(self, config):
        super().__init__()
        width = config["d_model"]
        self.self_attn = AudioAttention(width, config["encoder_attention_heads"])
        self.self_attn_layer_norm = nn.LayerNorm(width)
        self.fc1 = nn.Linear(width, config["encoder_ffn_dim"])
        self.fc2 = nn.Linear(config["encoder_ffn_dim"], width)
        self.final_layer_norm = nn.LayerNorm(width)

    def forward(self, x):
        x = x + self.self_attn(self.self_attn_layer_norm(x))
        return x + self.fc2(F.gelu(self.fc1(self.final_layer_norm(x))))


class AudioEncoder(nn.Module):
    """The encoder's attention layers and output projection over one window of rows, which
    attend to each other with no mask."""

    def __init__(self, config):
        super().__init__()
        width = config["d_model"]
        self.layers = nn.ModuleList(AudioEncoderLayer(config) for _ in range(config["encoder_layers"]))
        self.ln_post = nn.LayerNorm(width)
        self.proj1 = nn.Linear(width, width)
        self.proj2 = nn.Linear(width, config["output_dim"])

    def forward(self, rows):
        for layer in self.layers:
            rows = layer(rows)
        return self.proj2(F.gelu(self.proj1(self.ln_post(rows))))


# MARK: - Language model


class RMSNorm(nn.Module):
    def __init__(self, width, eps):
        super().__init__()
        self.weight = nn.Parameter(torch.ones(width))
        self.eps = eps

    def forward(self, x):
        return x * torch.rsqrt(x.pow(2).mean(-1, keepdim=True) + self.eps) * self.weight


def rotate(x, cos, sin, half):
    """MLX's RoPE, not traditional: the first half of each head turns against the second. cos and
    sin span the whole head, each angle twice.

    Written as transformers' apply_rotary_pos_emb writes it, with the halves' bounds spelled out.
    OpenVINO's CPU plugin (2026.2.1) fuses this form into its RoPE node and brings it back from its
    model cache intact; the half-width form (cat([a * cos - b * sin, b * cos + a * sin])) also fuses,
    but comes back from the cache broken, NaN from the app's second start on. check_cache guards it."""
    first, second = x[..., 0:half], x[..., half : 2 * half]
    return x * cos + torch.cat([-second, first], dim=-1) * sin


def repeat_heads(x, times):
    """transformers' repeat_kv, which OpenVINO recognises in its attention fusions."""
    batch, heads, length, width = x.shape
    return x[:, :, None].expand(batch, heads, times, length, width).reshape(batch, heads * times, length, width)


class TextAttention(nn.Module):
    def __init__(self, config):
        super().__init__()
        width, head = config["hidden_size"], config["head_dim"]
        self.heads = config["num_attention_heads"]
        self.kv_heads = config["num_key_value_heads"]
        self.scale = head**-0.5
        self.half = head // 2
        self.q_proj = nn.Linear(width, self.heads * head, bias=False)
        self.k_proj = nn.Linear(width, self.kv_heads * head, bias=False)
        self.v_proj = nn.Linear(width, self.kv_heads * head, bias=False)
        self.o_proj = nn.Linear(self.heads * head, width, bias=False)
        self.q_norm = RMSNorm(head, config["rms_norm_eps"])
        self.k_norm = RMSNorm(head, config["rms_norm_eps"])

    def forward(self, x, cos, sin, mask, past_key, past_value):
        q = self.q_norm(self.q_proj(x).unflatten(-1, (self.heads, -1))).transpose(1, 2)
        k = self.k_norm(self.k_proj(x).unflatten(-1, (self.kv_heads, -1))).transpose(1, 2)
        v = self.v_proj(x).unflatten(-1, (self.kv_heads, -1)).transpose(1, 2)
        key = torch.cat([past_key, rotate(k, cos, sin, self.half)], dim=2)
        value = torch.cat([past_value, v], dim=2)
        times = self.heads // self.kv_heads
        attended = F.scaled_dot_product_attention(
            rotate(q, cos, sin, self.half), repeat_heads(key, times), repeat_heads(value, times), attn_mask=mask, scale=self.scale
        )
        return self.o_proj(attended.transpose(1, 2).flatten(2)), key, value


class TextMLP(nn.Module):
    def __init__(self, config):
        super().__init__()
        width, inner = config["hidden_size"], config["intermediate_size"]
        self.gate_proj = nn.Linear(width, inner, bias=False)
        self.up_proj = nn.Linear(width, inner, bias=False)
        self.down_proj = nn.Linear(inner, width, bias=False)

    def forward(self, x):
        return self.down_proj(F.silu(self.gate_proj(x)) * self.up_proj(x))


class TextDecoderLayer(nn.Module):
    def __init__(self, config):
        super().__init__()
        self.self_attn = TextAttention(config)
        self.mlp = TextMLP(config)
        self.input_layernorm = RMSNorm(config["hidden_size"], config["rms_norm_eps"])
        self.post_attention_layernorm = RMSNorm(config["hidden_size"], config["rms_norm_eps"])

    def forward(self, x, cos, sin, mask, past_key, past_value):
        attended, key, value = self.self_attn(self.input_layernorm(x), cos, sin, mask, past_key, past_value)
        x = x + attended
        return x + self.mlp(self.post_attention_layernorm(x)), key, value


class TextModel(nn.Module):
    """Qwen3's decoder as the Mac runs it: plain RoPE over positions 0, 1, 2… (the checkpoint's
    multimodal RoPE turns every section by the same position when only audio and text are in the
    prompt, which is the same), a causal mask, and logits from the tied embeddings.

    Inputs: input_ids [1, n]; audio_rows [1, n, hidden], used where audio_mask [1, n] is 1 in place
    of the token's embedding; position_ids [1, n], continuing the cache; then each layer's cached
    key and value. Outputs: the logits after the last position [1, 1, vocab], then each layer's
    key and value with this call's positions appended."""

    def __init__(self, config):
        super().__init__()
        self.embed_tokens = nn.Embedding(config["vocab_size"], config["hidden_size"])
        self.layers = nn.ModuleList(TextDecoderLayer(config) for _ in range(config["num_hidden_layers"]))
        self.norm = RMSNorm(config["hidden_size"], config["rms_norm_eps"])
        self.lm_head = (
            None
            if config["tie_word_embeddings"]
            else nn.Linear(config["hidden_size"], config["vocab_size"], bias=False)
        )
        head = config["head_dim"]
        frequencies = 1.0 / config["rope_theta"] ** (torch.arange(0, head, 2, dtype=torch.float32) / head)
        self.register_buffer("frequencies", frequencies, persistent=False)

    def forward(self, input_ids, audio_rows, audio_mask, position_ids, *past):
        x = torch.where(audio_mask.unsqueeze(-1) > 0, audio_rows, self.embed_tokens(input_ids))
        angles = position_ids.unsqueeze(-1).to(torch.float32) * self.frequencies
        angles = torch.cat([angles, angles], dim=-1)
        cos, sin = angles.cos().unsqueeze(1), angles.sin().unsqueeze(1)
        # Cached position j holds token j, so a token sees every key up to its own position.
        keys = torch.arange(past[0].shape[2] + input_ids.shape[1])
        mask = (keys <= position_ids.unsqueeze(-1)).unsqueeze(1)
        presents = []
        for index, layer in enumerate(self.layers):
            x, key, value = layer(x, cos, sin, mask, past[2 * index], past[2 * index + 1])
            presents += [key, value]
        last = self.norm(x[:, -1:])
        logits = self.lm_head(last) if self.lm_head is not None else last @ self.embed_tokens.weight.T
        return (logits, *presents)


# MARK: - Checkpoint


def load_checkpoint(folder):
    from safetensors.torch import load_file

    shards = sorted(folder.glob("*.safetensors"))
    if not shards:
        sys.exit(f"{folder} holds no .safetensors weights")
    weights = {}
    for shard in shards:
        weights.update(load_file(shard))
    return {name.removeprefix("thinker."): tensor.to(torch.float32) for name, tensor in weights.items()}


def load_into(module, weights, prefix):
    """Loads `module`'s weights, each named `prefix` + its name in the module, and stops unless
    the checkpoint has every one in the right shape. (main checks that no weight is left over.)"""
    names = module.state_dict().keys()
    missing = [prefix + name for name in names if prefix + name not in weights]
    if missing:
        sys.exit(f"the checkpoint lacks {type(module).__name__}'s weights: {missing[:8]}")
    module.load_state_dict({name: weights[prefix + name] for name in names}, strict=True)
    module.eval()
    return module


# MARK: - Conversion


def name_ports(ports, names):
    for port, name in zip(ports, names, strict=True):
        port.get_tensor().set_names({name})


def convert_audio(conv, encoder, audio_config):
    import openvino as ov

    width = audio_config["d_model"]
    conv_model = ov.convert_model(
        conv,
        example_input=torch.randn(2, audio_config["num_mel_bins"], 100),
        input=[(ov.PartialShape([-1, audio_config["num_mel_bins"], -1]), ov.Type.f32)],
    )
    name_ports(conv_model.inputs, ["chunks"])
    name_ports(conv_model.outputs, ["rows"])

    encoder_model = ov.convert_model(
        encoder,
        example_input=torch.randn(1, 30, width),
        input=[(ov.PartialShape([1, -1, width]), ov.Type.f32)],
    )
    name_ports(encoder_model.inputs, ["rows"])
    name_ports(encoder_model.outputs, ["embeddings"])
    return conv_model, encoder_model


def kv_names(layers, kind):
    return [f"{kind}.{index}.{part}" for index in range(layers) for part in ("key", "value")]


def convert_text(text, text_config):
    import openvino as ov
    from openvino._offline_transformations import apply_make_stateful_transformation

    layers, width = text_config["num_hidden_layers"], text_config["hidden_size"]
    kv_shape = [1, text_config["num_key_value_heads"], -1, text_config["head_dim"]]
    example = (
        torch.randint(0, 1000, (1, 5)),
        torch.randn(1, 5, width),
        torch.tensor([[0, 1, 1, 0, 0]]),
        torch.arange(3, 8)[None],
        *(torch.randn(1, kv_shape[1], 3, kv_shape[3]) for _ in range(2 * layers)),
    )
    inputs = [
        (ov.PartialShape([1, -1]), ov.Type.i64),
        (ov.PartialShape([1, -1, width]), ov.Type.f32),
        (ov.PartialShape([1, -1]), ov.Type.i64),
        (ov.PartialShape([1, -1]), ov.Type.i64),
    ] + [(ov.PartialShape(kv_shape), ov.Type.f32)] * (2 * layers)
    model = ov.convert_model(text, example_input=example, input=inputs)
    name_ports(model.inputs, ["input_ids", "audio_rows", "audio_mask", "position_ids", *kv_names(layers, "past")])
    name_ports(model.outputs, ["logits", *kv_names(layers, "present")])
    # The cache becomes state inside the model: each request starts with an empty one.
    apply_make_stateful_transformation(
        model, dict(zip(kv_names(layers, "past"), kv_names(layers, "present"), strict=True))
    )
    return model


# MARK: - Checks against PyTorch


def compare(label, expected, actual, tolerance):
    expected, actual = np.asarray(expected, np.float32), np.asarray(actual, np.float32)
    if expected.shape != actual.shape:
        sys.exit(f"{label}: OpenVINO gave shape {actual.shape}, PyTorch {expected.shape}")
    difference = float(np.abs(expected - actual).max())
    scale = float(np.abs(expected).max()) or 1.0
    LOG.info("%s: largest difference %.3g (%.3g of the largest value)", label, difference, difference / scale)
    if difference / scale > tolerance:
        sys.exit(f"{label}: OpenVINO differs from PyTorch by {difference / scale:.3g}, over {tolerance}")


def check_audio(core, out, conv, encoder, audio_config, device):
    generator = torch.Generator().manual_seed(0)
    conv_model = core.compile_model(out / "audio-conv.xml", device)
    for chunks, frames in [(3, 100), (2, 37)]:
        mel = torch.randn(chunks, audio_config["num_mel_bins"], frames, generator=generator)
        with torch.no_grad():
            expected = conv(mel).numpy()
        compare(f"audio-conv {chunks}x{frames}", expected, conv_model(mel.numpy())[0], 2e-2)

    encoder_model = core.compile_model(out / "audio-encoder.xml", device)
    for length in [13, 104]:
        rows = torch.randn(1, length, audio_config["d_model"], generator=generator)
        with torch.no_grad():
            expected = encoder(rows).numpy()
        compare(f"audio-encoder {length} rows", expected, encoder_model(rows.numpy())[0], 2e-2)


def check_text(core, out, text, text_config, prompt_ids, audio_start, device):
    """A prompt with rows in place of its first placeholders, then three greedy steps: PyTorch
    with the cache passed around, OpenVINO with the cache as state."""
    generator = torch.Generator().manual_seed(1)
    layers, width = text_config["num_hidden_layers"], text_config["hidden_size"]
    ids = torch.tensor([prompt_ids])
    rows = torch.zeros(1, len(prompt_ids), width)
    mask = torch.zeros(1, len(prompt_ids), dtype=torch.int64)
    audio = slice(audio_start, audio_start + 6)
    rows[0, audio] = torch.randn(6, width, generator=generator) * 0.05
    mask[0, audio] = 1
    positions = torch.arange(len(prompt_ids))[None]
    empty = [torch.zeros(1, text_config["num_key_value_heads"], 0, text_config["head_dim"]) for _ in range(2 * layers)]

    request = core.compile_model(out / "text.xml", device).create_infer_request()
    feeds = {"input_ids": ids, "audio_rows": rows, "audio_mask": mask, "position_ids": positions}
    with torch.no_grad():
        logits, *past = text(ids, rows, mask, positions, *empty)
    agreed = 0
    for step in range(4):
        actual = request.infer({name: value.numpy() for name, value in feeds.items()})["logits"]
        expected = logits.numpy()
        compare(f"text step {step}", expected, actual, 0.15)
        token = int(expected[0, -1].argmax())
        agreed += int(actual[0, -1].argmax()) == token
        position = torch.tensor([[len(prompt_ids) + step]])
        feeds = {
            "input_ids": torch.tensor([[token]]),
            "audio_rows": torch.zeros(1, 1, width),
            "audio_mask": torch.zeros(1, 1, dtype=torch.int64),
            "position_ids": position,
        }
        with torch.no_grad():
            logits, *past = text(feeds["input_ids"], feeds["audio_rows"], feeds["audio_mask"], position, *past)
    LOG.info("text: OpenVINO chose PyTorch's next token in %d of 4 steps", agreed)
    if agreed < 3:
        sys.exit("the converted language model picks different tokens from PyTorch")


def check_cache(out, audio_config, text_feeds, device):
    """Compiles each model twice through one new model cache, as the app's first and later starts
    do, and checks the model imported from the cache computes what the freshly compiled one did."""
    import openvino as ov

    generator = np.random.default_rng(2)
    cases = {
        "audio-conv.xml": {"chunks": generator.standard_normal((2, audio_config["num_mel_bins"], 50), dtype=np.float32)},
        "audio-encoder.xml": {"rows": generator.standard_normal((1, 13, audio_config["d_model"]), dtype=np.float32)},
        "text.xml": text_feeds,
    }
    with tempfile.TemporaryDirectory() as cache:
        for name, feeds in cases.items():
            outputs = []
            for _ in range(2):
                core = ov.Core()
                core.set_property({"CACHE_DIR": cache})
                outputs.append(core.compile_model(out / name, device).create_infer_request().infer(feeds)[0].copy())
            if not np.isfinite(outputs[1]).all():
                sys.exit(f"{name} gives NaN or infinity once imported from OpenVINO's model cache")
            compare(f"{name} from the model cache", outputs[0], outputs[1], 1e-4)


def prompt_for_check(folder, audio_token, placeholders):
    """The app's prompt with `placeholders` audio placeholders, from the tokenizer's vocabulary."""
    added = json.loads((folder / "tokenizer_config.json").read_text())["added_tokens_decoder"]
    special = {entry["content"]: int(token) for token, entry in added.items()}
    vocab = json.loads((folder / "vocab.json").read_text())
    newline = vocab["Ċ"]
    ids = [special["<|im_start|>"], vocab["system"], newline, special["<|im_end|>"], newline]
    ids += [special["<|im_start|>"], vocab["user"], newline, special["<|audio_start|>"]]
    audio_start = len(ids)
    ids += [audio_token] * placeholders
    ids += [special["<|audio_end|>"], special["<|im_end|>"], newline, special["<|im_start|>"], vocab["assistant"], newline]
    return ids, audio_start


# MARK: - Main


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--model", type=Path, required=True, help="folder with config.json and model.safetensors")
    parser.add_argument("--out", type=Path, required=True, help="folder to write the app's model to")
    parser.add_argument(
        "--text-weights",
        choices=["int8", "fp16"],
        default="int8",
        help="the language model's weights: int8 (the default, like the Mac's 8-bit model) or fp16",
    )
    parser.add_argument("--source", default="", help="where the checkpoint came from, for the manifest")
    parser.add_argument("--device", default="CPU", help="OpenVINO device the checks run on")
    parser.add_argument("--skip-checks", action="store_true", help="don't compare the models with PyTorch")
    arguments = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s", datefmt="%H:%M:%S")

    import nncf
    import openvino as ov

    started = time.monotonic()
    config = json.loads((arguments.model / "config.json").read_text())
    thinker = config.get("thinker_config", config)
    audio_config, text_config = thinker["audio_config"], thinker["text_config"]
    torch.set_grad_enabled(False)

    LOG.info("Loading %s", arguments.model)
    weights = load_checkpoint(arguments.model)
    conv = load_into(AudioConvolutions(audio_config), weights, "audio_tower.")
    encoder = load_into(AudioEncoder(audio_config), weights, "audio_tower.")
    text = load_into(TextModel(text_config), weights, "model.")
    used = {f"audio_tower.{name}" for name in conv.state_dict()} | {f"audio_tower.{name}" for name in encoder.state_dict()}
    used |= {f"model.{name}" for name in text.state_dict()}
    unused = sorted(set(weights) - used - ({"lm_head.weight"} if text_config["tie_word_embeddings"] else set()))
    if unused:
        sys.exit(f"the checkpoint has weights the passes don't use: {unused[:8]}")
    del weights

    out = arguments.out
    partial = out.with_name(out.name + ".part")
    shutil.rmtree(partial, ignore_errors=True)
    partial.mkdir(parents=True)

    LOG.info("Converting the audio encoder")
    conv_model, encoder_model = convert_audio(conv, encoder, audio_config)
    ov.save_model(conv_model, partial / "audio-conv.xml", compress_to_fp16=True)
    ov.save_model(encoder_model, partial / "audio-encoder.xml", compress_to_fp16=True)

    LOG.info("Converting the language model")
    text_model = convert_text(text, text_config)
    if arguments.text_weights == "int8":
        text_model = nncf.compress_weights(text_model, mode=nncf.CompressWeightsMode.INT8_ASYM)
    ov.save_model(text_model, partial / "text.xml", compress_to_fp16=True)
    del text_model

    for name in COPIED_FILES:
        shutil.copyfile(arguments.model / name, partial / name)
    manifest = {
        "format": MANIFEST_FORMAT,
        "model": "qwen3-asr",
        "source": arguments.source or str(arguments.model),
        "audio": {
            "mel_bins": audio_config["num_mel_bins"],
            "width": audio_config["d_model"],
            "output_width": audio_config["output_dim"],
        },
        "text": {
            "width": text_config["hidden_size"],
            "vocab_size": text_config["vocab_size"],
            "layers": text_config["num_hidden_layers"],
            "audio_token_id": thinker["audio_token_id"],
        },
        "weights": {"audio": "fp16", "text": arguments.text_weights},
        "exported_with": {"openvino": ov.get_version(), "nncf": nncf.__version__, "torch": torch.__version__},
    }
    (partial / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")

    if not arguments.skip_checks:
        LOG.info("Checking the converted models against PyTorch on %s", arguments.device)
        core = ov.Core()
        check_audio(core, partial, conv, encoder, audio_config, arguments.device)
        prompt, audio_start = prompt_for_check(arguments.model, thinker["audio_token_id"], 10)
        check_text(core, partial, text, text_config, prompt, audio_start, arguments.device)
        text_feeds = {
            "input_ids": np.array([prompt], np.int64),
            "audio_rows": np.zeros((1, len(prompt), text_config["hidden_size"]), np.float32),
            "audio_mask": np.zeros((1, len(prompt)), np.int64),
            "position_ids": np.arange(len(prompt), dtype=np.int64)[None],
        }
        check_cache(partial, audio_config, text_feeds, arguments.device)

    shutil.rmtree(out, ignore_errors=True)
    partial.rename(out)
    size = sum(path.stat().st_size for path in out.iterdir()) / 1e9
    LOG.info("Wrote %s (%.2f GB) in %.0f s", out, size, time.monotonic() - started)


if __name__ == "__main__":
    main()
