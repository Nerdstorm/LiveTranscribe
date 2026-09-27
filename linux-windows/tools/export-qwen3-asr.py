#!/usr/bin/env python3
"""Converts Qwen3-ASR to the OpenVINO models the Linux and Windows app runs.

The app computes the model's input features, its prompt and the decoding itself, as the Mac app's
mlx-audio-swift does (crates/transcription), and asks a runtime only for the model's forward
passes (its SpeechModel trait). This script writes those passes as four OpenVINO models:

  audio-conv       the audio encoder's convolutions and positional embedding, over chunks of mel
                   frames: chunks [n, 128, frames] -> rows [n, rows, d_model]
  audio-encoder    its attention layers and output projection, over one window of rows, of which
                   mask marks the real ones: rows [1, r, d_model], mask [1, r] -> embeddings
                   [1, r, hidden]
  text-embeddings  the language model's token embeddings: input_ids [1, n] -> embeddings
                   [1, n, hidden], into which the app puts the audio rows
  text             the language model, with its KV cache kept as state, in the form OpenVINO's LLM
                   pipelines take (inputs_embeds, attention_mask, position_ids, beam_idx), to the
                   logits of the next token [1, 1, vocab]

Every dimension but the widths is left open, which the CPU takes as it is. The NPU compiles only
fixed shapes: the app fixes the audio models' (one chunk of 100 frames; a window padded to 104
rows, the padding masked out), and the NPU's LLM mode (NPUW) fixes the language model's, padding
the prompt on the left and keeping the cache in fixed slots that attention_mask marks.

The passes are written here in PyTorch as mlx-audio-swift's Qwen3ASR.swift computes them, not
taken from transformers, whose model chunks audio the reference way. The checkpoint's weights
load into them strictly, and each converted model is checked against its PyTorch pass, on the
CPU and, when there is one, on the NPU.

Run it with the model tools the setup kit installs, inside the live-transcribe toolbox:

    ~/.local/share/live-transcribe/model-tools/bin/python export-qwen3-asr.py \\
        --model <folder with config.json and model.safetensors> \\
        --out ~/.local/share/live-transcribe/models/qwen3-asr-0.6b-v2
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
MANIFEST_FORMAT = 2
# What the app reads from the checkpoint besides the models: its languages and its tokenizer.
COPIED_FILES = ["config.json", "vocab.json", "merges.txt", "tokenizer_config.json"]
# What a masked attention score gets: far below any real score, so it weighs nothing, yet finite in
# 16-bit floats (the NPU's), so a row with nothing to attend to, such as a padded prompt position,
# averages its values rather than turning to NaN and spreading.
MASKED = -10_000.0
# Mel frames in a chunk, and the rows of a full window (8 chunks of 13 rows): the audio models'
# fixed shapes on the NPU, where the app pads every window to WINDOW_ROWS.
CHUNK_FRAMES = 100
WINDOW_ROWS = 104
# The NPU's LLM mode (NPUW) for the checks here: room for the check's prompt and its steps. The app
# sets its own.
# --text-weights: how NNCF compresses the language model's and its embeddings' weights, per channel.
# int8 is symmetric: the NPU's LLM mode runs it at about 16 ms a token, and asymmetric int8 at about
# 870 ms; the CPU runs both alike. fp16 is there for comparisons.
TEXT_WEIGHTS = {"int8": "INT8_SYM", "fp16": None}
NPUW_CHECK = {
    "NPU_USE_NPUW": "YES",
    "NPUW_LLM": "YES",
    "NPUW_LLM_MAX_PROMPT_LEN": "128",
    "NPUW_LLM_MIN_RESPONSE_LEN": "64",
}


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

    def forward(self, x, bias):
        q, k, v = (
            projection(x).unflatten(-1, (self.heads, -1)).transpose(1, 2)
            for projection in (self.q_proj, self.k_proj, self.v_proj)
        )
        attended = F.scaled_dot_product_attention(q, k, v, attn_mask=bias, scale=self.scale)
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

    def forward(self, x, bias):
        x = x + self.self_attn(self.self_attn_layer_norm(x), bias)
        return x + self.fc2(F.gelu(self.fc1(self.final_layer_norm(x))))


class AudioEncoder(nn.Module):
    """The encoder's attention layers and output projection over one window of rows, which
    attend to each other with no mask, as the Mac's do. On the NPU the window is padded to a fixed
    length: mask is 1 for the real rows and 0 for the padding, which nothing attends to, so the
    real rows come out as they would from a window of only them."""

    def __init__(self, config):
        super().__init__()
        width = config["d_model"]
        self.layers = nn.ModuleList(AudioEncoderLayer(config) for _ in range(config["encoder_layers"]))
        self.ln_post = nn.LayerNorm(width)
        self.proj1 = nn.Linear(width, width)
        self.proj2 = nn.Linear(width, config["output_dim"])

    def forward(self, rows, mask):
        bias = (1 - mask[:, None, None, :].to(rows.dtype)) * MASKED
        for layer in self.layers:
            rows = layer(rows, bias)
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

    def forward(self, x, cos, sin, bias, past_key, past_value):
        q = self.q_norm(self.q_proj(x).unflatten(-1, (self.heads, -1))).transpose(1, 2)
        k = self.k_norm(self.k_proj(x).unflatten(-1, (self.kv_heads, -1))).transpose(1, 2)
        v = self.v_proj(x).unflatten(-1, (self.kv_heads, -1)).transpose(1, 2)
        key = torch.cat([past_key, rotate(k, cos, sin, self.half)], dim=2)
        value = torch.cat([past_value, v], dim=2)
        times = self.heads // self.kv_heads
        attended = F.scaled_dot_product_attention(
            rotate(q, cos, sin, self.half), repeat_heads(key, times), repeat_heads(value, times), attn_mask=bias, scale=self.scale
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

    def forward(self, x, cos, sin, bias, past_key, past_value):
        attended, key, value = self.self_attn(self.input_layernorm(x), cos, sin, bias, past_key, past_value)
        x = x + attended
        return x + self.mlp(self.post_attention_layernorm(x)), key, value


class TextEmbeddings(nn.Module):
    """The language model's token embeddings, on their own: the app puts the audio rows in place
    of the placeholders' embeddings before the language model sees them. Shares the language
    model's embedding table."""

    def __init__(self, embed_tokens):
        super().__init__()
        self.embed_tokens = embed_tokens

    def forward(self, input_ids):
        return self.embed_tokens(input_ids)


class TextModel(nn.Module):
    """Qwen3's decoder as the Mac runs it: plain RoPE over positions 0, 1, 2… (the checkpoint's
    multimodal RoPE turns every section by the same position when only audio and text are in the
    prompt, which is the same), a causal mask, and logits from the tied embeddings.

    Inputs, as OpenVINO's LLM pipelines name them: inputs_embeds [1, n, hidden], the tokens'
    embeddings with the audio rows in place of the placeholders'; attention_mask [1, past + n],
    1 for each cache slot and new position to attend to; position_ids [1, n]; then each layer's
    cached key and value. Outputs: the logits after the last position [1, 1, vocab], then each
    layer's key and value with this call's appended.

    A position attends to the cache slots and new positions up to its own, where attention_mask
    is 1. On the CPU the mask is all ones and the slots are the positions. The NPU's LLM mode keeps
    the cache in a fixed number of slots, the unused ones masked, and pads a prompt on the left,
    the padding masked too."""

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

    def forward(self, inputs_embeds, attention_mask, position_ids, *past):
        x = inputs_embeds
        angles = position_ids.unsqueeze(-1).to(torch.float32) * self.frequencies
        angles = torch.cat([angles, angles], dim=-1)
        cos, sin = angles.cos().unsqueeze(1), angles.sin().unsqueeze(1)
        # This call's positions take the slots after the cache's, in order.
        cached = past[0].shape[2]
        slots = torch.arange(cached + inputs_embeds.shape[1])
        own = cached + torch.arange(inputs_embeds.shape[1])
        allowed = (slots <= own.unsqueeze(-1)) & (attention_mask.unsqueeze(1) > 0)
        bias = torch.where(allowed, 0.0, MASKED).unsqueeze(1)
        presents = []
        for index, layer in enumerate(self.layers):
            x, key, value = layer(x, cos, sin, bias, past[2 * index], past[2 * index + 1])
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
        example_input=(torch.randn(1, 30, width), torch.ones(1, 30, dtype=torch.int64)),
        input=[(ov.PartialShape([1, -1, width]), ov.Type.f32), (ov.PartialShape([1, -1]), ov.Type.i64)],
    )
    name_ports(encoder_model.inputs, ["rows", "mask"])
    name_ports(encoder_model.outputs, ["embeddings"])
    return conv_model, encoder_model


def convert_embeddings(embeddings):
    import openvino as ov

    model = ov.convert_model(
        embeddings,
        example_input=torch.randint(0, 1000, (1, 5)),
        input=[(ov.PartialShape([1, -1]), ov.Type.i64)],
    )
    name_ports(model.inputs, ["input_ids"])
    name_ports(model.outputs, ["embeddings"])
    return model


def kv_names(layers, kind):
    return [f"{kind}.{index}.{part}" for index in range(layers) for part in ("key", "value")]


def add_beam_idx(model, cache_inputs):
    """OpenVINO's LLM pipelines, the NPU's included, choose each cache's rows through a beam_idx
    input before a step, for beam search. The app decodes one sequence and passes [0]."""
    import openvino as ov
    import openvino.opset13 as ops

    beam_idx = ops.parameter(ov.PartialShape([1]), ov.Type.i32, name="beam_idx")
    beam_idx.output(0).get_tensor().set_names({"beam_idx"})
    model.add_parameters([beam_idx])
    for name in cache_inputs:
        port = model.input(name)
        consumers = port.get_target_inputs()
        chosen = ops.gather(port, beam_idx, ops.constant(0))
        for consumer in consumers:
            consumer.replace_source_output(chosen.output(0))
    model.validate_nodes_and_infer_types()


def convert_text(text, text_config):
    import openvino as ov
    from openvino._offline_transformations import apply_make_stateful_transformation

    layers, width = text_config["num_hidden_layers"], text_config["hidden_size"]
    kv_shape = [1, text_config["num_key_value_heads"], -1, text_config["head_dim"]]
    example = (
        torch.randn(1, 5, width),
        torch.ones(1, 8, dtype=torch.int64),
        torch.arange(3, 8)[None],
        *(torch.randn(1, kv_shape[1], 3, kv_shape[3]) for _ in range(2 * layers)),
    )
    inputs = [
        (ov.PartialShape([1, -1, width]), ov.Type.f32),
        (ov.PartialShape([1, -1]), ov.Type.i64),
        (ov.PartialShape([1, -1]), ov.Type.i64),
    ] + [(ov.PartialShape(kv_shape), ov.Type.f32)] * (2 * layers)
    model = ov.convert_model(text, example_input=example, input=inputs)
    past, present = kv_names(layers, "past_key_values"), kv_names(layers, "present")
    name_ports(model.inputs, ["inputs_embeds", "attention_mask", "position_ids", *past])
    name_ports(model.outputs, ["logits", *present])
    add_beam_idx(model, past)
    # The cache becomes state inside the model, named as OpenVINO's LLM pipelines expect: each
    # request starts with an empty one.
    apply_make_stateful_transformation(model, dict(zip(past, present, strict=True)))
    add_state_initializers(model)
    return model


def add_state_initializers(model):
    """Gives each cache's state an initializer, an empty cache as wide as the batch, as
    optimum-intel's exports have. OpenVINO's CPU plugin fails to compile the cache's beam_idx
    reordering without one ("ReadValue contains less parent edges than 0")."""
    import openvino.opset13 as ops

    embeds = model.input("inputs_embeds")
    batch = ops.gather(ops.shape_of(embeds, output_type="i64"), ops.constant([0]), ops.constant(0))
    for op in model.get_ops():
        if op.get_type_name() != "ReadValue":
            continue
        # An empty cache: the sequence's dimension, the only open one, starts at 0.
        dims = [dim.min_length for dim in op.get_output_partial_shape(0)]
        dims[0] = batch
        dims = [ops.constant(np.array([dim], np.int64)) if isinstance(dim, int) else dim for dim in dims]
        empty = ops.broadcast(ops.constant(0.0, dtype=op.get_output_element_type(0)), ops.concat(dims, axis=0))
        op.set_arguments([empty])
    model.validate_nodes_and_infer_types()


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


def compile_for(core, out, name, device, audio_config):
    """`name` compiled for `device` as the app compiles it: on the NPU the audio models get their
    fixed shapes and the language model the NPU's LLM mode. The app runs text-embeddings on the
    CPU."""
    model = core.read_model(out / f"{name}.xml")
    config = {}
    if device == "NPU":
        if name == "audio-conv":
            model.reshape({"chunks": [1, audio_config["num_mel_bins"], CHUNK_FRAMES]})
        elif name == "audio-encoder":
            model.reshape({"rows": [1, WINDOW_ROWS, audio_config["d_model"]], "mask": [1, WINDOW_ROWS]})
        elif name == "text":
            config = NPUW_CHECK
    return core.compile_model(model, device, config)


def check_audio(core, out, conv, encoder, audio_config, device, tolerance):
    generator = torch.Generator().manual_seed(0)
    fixed = device == "NPU"
    conv_model = compile_for(core, out, "audio-conv", device, audio_config)
    for chunks, frames in [(1, CHUNK_FRAMES)] if fixed else [(3, CHUNK_FRAMES), (2, 37)]:
        mel = torch.randn(chunks, audio_config["num_mel_bins"], frames, generator=generator)
        with torch.no_grad():
            expected = conv(mel).numpy()
        compare(f"audio-conv {chunks}x{frames} on {device}", expected, conv_model(mel.numpy())[0], tolerance)

    # Whole windows, and a short one padded to a whole window, its padding noise that the mask
    # must hide: the real rows must come out as PyTorch makes them from the short window alone.
    encoder_model = compile_for(core, out, "audio-encoder", device, audio_config)
    for length in [13, 50, WINDOW_ROWS]:
        rows = torch.randn(1, length, audio_config["d_model"], generator=generator)
        with torch.no_grad():
            expected = encoder(rows, torch.ones(1, length, dtype=torch.int64)).numpy()
        padded = WINDOW_ROWS if fixed or length == 50 else length
        feeds = {
            "rows": np.concatenate([rows.numpy(), np.random.default_rng(length).standard_normal(
                (1, padded - length, audio_config["d_model"]), dtype=np.float32)], axis=1),
            "mask": (np.arange(padded) < length).astype(np.int64)[None],
        }
        actual = encoder_model(feeds)[0][:, :length]
        compare(f"audio-encoder {length} of {padded} rows on {device}", expected, actual, tolerance)


def check_text(core, out, text, embeddings, text_config, prompt_ids, audio_start, device, audio_config):
    """A prompt with rows in place of its first placeholders, then three greedy steps: PyTorch
    with the cache passed around, OpenVINO with the cache as state."""
    generator = torch.Generator().manual_seed(1)
    layers = text_config["num_hidden_layers"]
    length = len(prompt_ids)
    audio = torch.randn(6, text_config["hidden_size"], generator=generator) * 0.05
    with torch.no_grad():
        embeds = embeddings(torch.tensor([prompt_ids]))
    embeds[0, audio_start : audio_start + 6] = audio
    empty = [torch.zeros(1, text_config["num_key_value_heads"], 0, text_config["head_dim"]) for _ in range(2 * layers)]

    embed = compile_for(core, out, "text-embeddings", "CPU", audio_config)
    compiled = compile_for(core, out, "text", device, audio_config)
    request = compiled.create_infer_request()
    beam = beam_feed(compiled)
    ov_embeds = embed(np.array([prompt_ids], np.int64))[0].copy()
    ov_embeds[0, audio_start : audio_start + 6] = audio.numpy()
    feeds = {
        "inputs_embeds": ov_embeds,
        "attention_mask": np.ones((1, length), np.int64),
        "position_ids": np.arange(length, dtype=np.int64)[None],
        **beam,
    }
    with torch.no_grad():
        logits, *past = text(embeds, torch.ones(1, length, dtype=torch.int64), torch.arange(length)[None], *empty)
    agreed = 0
    for step in range(4):
        actual = request.infer(feeds)["logits"]
        expected = logits.numpy()
        compare(f"text step {step} on {device}", expected, actual, 0.15)
        token = int(expected[0, -1].argmax())
        agreed += int(actual[0, -1].argmax()) == token
        seen = length + step + 1
        feeds = {
            "inputs_embeds": embed(np.array([[token]], np.int64))[0].copy(),
            "attention_mask": np.ones((1, seen), np.int64),
            "position_ids": np.array([[length + step]], np.int64),
            **beam,
        }
        with torch.no_grad():
            logits, *past = text(
                embeddings(torch.tensor([[token]])), torch.ones(1, seen, dtype=torch.int64), torch.tensor([[length + step]]), *past
            )
    LOG.info("text on %s: OpenVINO chose PyTorch's next token in %d of 4 steps", device, agreed)
    if agreed < 3:
        sys.exit(f"the converted language model picks different tokens from PyTorch on {device}")


def check_cache(out, audio_config, text_config, prompt, device):
    """Compiles each model twice through one new model cache, as the app's first and later starts
    do, and checks the model imported from the cache computes what the freshly compiled one did."""
    import openvino as ov

    generator = np.random.default_rng(2)
    fixed = device == "NPU"
    rows = WINDOW_ROWS if fixed else 13
    cases = {
        "audio-conv": {
            "chunks": generator.standard_normal(
                (1, audio_config["num_mel_bins"], CHUNK_FRAMES) if fixed else (2, audio_config["num_mel_bins"], 50),
                dtype=np.float32,
            )
        },
        "audio-encoder": {
            "rows": generator.standard_normal((1, rows, audio_config["d_model"]), dtype=np.float32),
            "mask": (np.arange(rows) < 13).astype(np.int64)[None],
        },
        "text": {
            "inputs_embeds": generator.standard_normal((1, len(prompt), text_config["hidden_size"]), dtype=np.float32) * 0.05,
            "attention_mask": np.ones((1, len(prompt)), np.int64),
            "position_ids": np.arange(len(prompt), dtype=np.int64)[None],
        },
    }
    with tempfile.TemporaryDirectory() as cache:
        for name, feeds in cases.items():
            outputs = []
            for _ in range(2):
                core = ov.Core()
                core.set_property({"CACHE_DIR": cache})
                compiled = compile_for(core, out, name, device, audio_config)
                if name == "text":
                    feeds = {**feeds, **beam_feed(compiled)}
                outputs.append(compiled.create_infer_request().infer(feeds)[0].copy())
            if not np.isfinite(outputs[1]).all():
                sys.exit(f"{name} gives NaN or infinity on {device} once imported from OpenVINO's model cache")
            compare(f"{name} on {device} from the model cache", outputs[0], outputs[1], 1e-4)


def beam_feed(compiled):
    """beam_idx for the language model, if it still takes it, as the app feeds it: the NPU's LLM
    mode may take that input away, having one reply at a time."""
    names = {name for port in compiled.inputs for name in port.get_names()}
    return {"beam_idx": np.zeros(1, np.int32)} if "beam_idx" in names else {}


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
        choices=list(TEXT_WEIGHTS),
        default="int8",
        help="the language model's weights: int8 (symmetric, the default) or fp16",
    )
    parser.add_argument("--source", default="", help="where the checkpoint came from, for the manifest")
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
    embeddings = TextEmbeddings(text.embed_tokens).eval()
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
    mode = TEXT_WEIGHTS[arguments.text_weights]
    for name, model in [("text-embeddings", convert_embeddings(embeddings)), ("text", convert_text(text, text_config))]:
        if mode:
            model = nncf.compress_weights(model, mode=getattr(nncf.CompressWeightsMode, mode))
        ov.save_model(model, partial / f"{name}.xml", compress_to_fp16=True)
        del model

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
        "weights": {"audio": "fp16", "text": (TEXT_WEIGHTS[arguments.text_weights] or "fp16").lower()},
        "exported_with": {"openvino": ov.get_version(), "nncf": nncf.__version__, "torch": torch.__version__},
    }
    (partial / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")

    if not arguments.skip_checks:
        core = ov.Core()
        prompt, audio_start = prompt_for_check(arguments.model, thinker["audio_token_id"], 10)
        # The NPU computes in 16-bit floats, so its audio gets a looser bound; its tokens are held
        # to the CPU's.
        devices = [("CPU", 2e-2)] + ([("NPU", 5e-2)] if "NPU" in core.available_devices else [])
        for device, tolerance in devices:
            LOG.info("Checking the converted models against PyTorch on %s", device)
            check_audio(core, partial, conv, encoder, audio_config, device, tolerance)
            check_text(core, partial, text, embeddings, text_config, prompt, audio_start, device, audio_config)
            check_cache(partial, audio_config, text_config, prompt, device)
        if len(devices) == 1:
            LOG.info("No NPU here, so the models weren't checked on one")

    shutil.rmtree(out, ignore_errors=True)
    partial.rename(out)
    size = sum(path.stat().st_size for path in out.iterdir()) / 1e9
    LOG.info("Wrote %s (%.2f GB) in %.0f s", out, size, time.monotonic() - started)


if __name__ == "__main__":
    main()
