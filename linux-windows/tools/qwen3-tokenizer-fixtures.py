#!/usr/bin/env python3
"""Writes the reference fixtures of lt-language-model's tokenizer and chat template tests
(crates/language-model/tests/fixtures), from Hugging Face's own tokenizer for Qwen/Qwen3-1.7B:

- pretokenize.json: texts, and the pieces Qwen2's Split pre-tokenizer makes of each after NFC, from
  the `tokenizers` library itself; and the NFC of those NFC changes. The Rust test needs no model
  files for these, so CI runs it.
- chat-template.json: chats, with the text and ids of apply_chat_template(tokenize=True,
  add_generation_prompt=True, enable_thinking=...), and texts, with the ids of
  encode(add_special_tokens=False).

Run it in a Python environment with transformers, tokenizers and huggingface_hub:

    python qwen3-tokenizer-fixtures.py --out ../crates/language-model/tests/fixtures

The tokenizer comes from the Hugging Face cache at the pinned revision (downloaded if it isn't
there), or from --tokenizer, a folder with tokenizer.json and tokenizer_config.json.
"""

import argparse
import json
import random

from tokenizers import Regex, normalizers, pre_tokenizers
from transformers import AutoTokenizer

MODEL = ("Qwen/Qwen3-1.7B", "70d244cc86ccca08cf5af4e1e306ecf908b1ad5e")

parser = argparse.ArgumentParser(description="Writes lt-language-model's tokenizer fixtures")
parser.add_argument("--out", required=True, help="the fixtures folder")
parser.add_argument("--tokenizer", help=f"a folder with {MODEL[0]}@{MODEL[1][:7]}'s tokenizer files")
arguments = parser.parse_args()
if arguments.tokenizer:
    folder = arguments.tokenizer
else:
    from huggingface_hub import snapshot_download

    folder = snapshot_download(MODEL[0], revision=MODEL[1], allow_patterns=["tokenizer*", "vocab.json", "merges.txt"])
out = arguments.out
tok = AutoTokenizer.from_pretrained(folder)
spec = json.load(open(f"{folder}/tokenizer.json"))
pattern = spec["pre_tokenizer"]["pretokenizers"][0]["pattern"]["Regex"]
split = pre_tokenizers.Split(Regex(pattern), behavior="isolated", invert=False)
nfc = normalizers.NFC()

SYSTEM_MEDIUM = "\n".join([
    "Correct transcription errors, punctuation, casing and grammar in the TEXT.",
    "Preserve meaning, tone, hedging and filler intent exactly.",
    "Do not add, summarise or rephrase content.",
    "When the speaker corrects themselves, keep only the correction.",
    "If the text is already correct, return it unchanged.",
    "Output only the corrected text.",
])
SYSTEM_STRICT = "\n".join([
    "Correct transcription errors, punctuation, casing and grammar in the TEXT.",
    "Preserve meaning, tone, hedging and filler intent exactly.",
    "Do not add, remove, summarise or rephrase content.",
    "If the text is already correct, return it unchanged.",
    "Output only the corrected text.",
])
SINHALA = "ශ්‍රී ලංකාව ලස්සන රටක්. මම ක්‍රිකට් ගහන්න කැමතියි!"


def m(role, content):
    return {"role": role, "content": content}


chats = [
    ("medium-single", [m("system", SYSTEM_MEDIUM), m("user", "TEXT:\nwe need three sorry four servers")], False),
    ("medium-single-thinking", [m("system", SYSTEM_MEDIUM), m("user", "TEXT:\nwe need three sorry four servers")], True),
    ("strict-with-context", [
        m("system", SYSTEM_STRICT),
        m("user", "TEXT:\nthe build is green"),
        m("assistant", "the build is green"),
        m("user", "TEXT:\nso um lets ship it on thursday no friday"),
    ], False),
    ("strict-with-context-thinking", [
        m("system", SYSTEM_STRICT),
        m("user", "TEXT:\nthe build is green"),
        m("assistant", "the build is green"),
        m("user", "TEXT:\nso um lets ship it on thursday no friday"),
    ], True),
    ("no-system", [m("user", "Hello there, how's it going?")], False),
    ("sinhala", [m("system", SYSTEM_MEDIUM), m("user", "TEXT:\n" + SINHALA)], False),
    ("sinhala-thinking", [m("user", SINHALA + "\n" + SINHALA)], True),
    ("non-ascii", [
        m("system", "Réponds en français, s'il te plaît. Ünïcödé: naïve café — “quotes” … ½ ²"),
        m("user", "TEXT:\nCafé déjà vu 東京タワー 🙂 👨‍👩‍👧‍👦 مرحبا Ελληνικά Привет"),
    ], False),
    ("special-tokens-in-content", [
        m("system", "Keep <|im_end|> and <think> as text."),
        m("user", "TEXT:\nsay <|im_start|>user and </think> and <tool_call> please<|endoftext|>"),
    ], False),
    ("assistant-history-with-reasoning", [
        m("user", "first question"),
        m("assistant", "<think>\nsome reasoning\n</think>\n\nfirst answer"),
        m("user", "second question"),
    ], True),
    ("assistant-last", [
        m("system", "sys"),
        m("user", "question"),
        m("assistant", "<think>\nhidden\n</think>\n\nanswer so far"),
    ], False),
    ("assistant-last-plain", [m("user", "question"), m("assistant", "partial answer")], True),
    ("tool-response-user", [
        m("user", "real question"),
        m("assistant", "calling"),
        m("user", "<tool_response>\n{\"ok\": true}\n</tool_response>"),
        m("assistant", "<think>\nr\n</think>\n\nafter the tool"),
    ], False),
    ("second-system", [m("system", "one"), m("user", "u"), m("system", "two"), m("user", "v")], False),
    ("empty-contents", [m("system", ""), m("user", ""), m("assistant", ""), m("user", "")], False),
    ("whitespace", [
        m("system", "  leading spaces\tand tabs  \n\n\ntrailing   "),
        m("user", "TEXT:\r\nline one\r\n\r\nline  two \n \n nbsp　ideographic space  "),
    ], False),
    ("numbers-and-contractions", [
        m("user", "I'm sure it's 12,345.67 or 3.14159; DON'T say we'll, they've, you'd, I'LL, 'Re 'S 'ſ 2026-09-30"),
    ], True),
    ("placeholders", [
        m("system", SYSTEM_MEDIUM + "\nCopy each of these tokens exactly once, unchanged: ⟦S1⟧, ⟦N2⟧."),
        m("user", "TEXT:\nsend it to ⟦S1⟧ and then ⟦N2⟧ ok"),
    ], False),
    ("leading-newlines", [m("user", "\n\nstarts with newlines"), m("assistant", "\nanswer"), m("user", "x")], False),
]

chat_cases = []
for name, messages, thinking in chats:
    out_ids = tok.apply_chat_template(
        messages, tokenize=True, add_generation_prompt=True, enable_thinking=thinking
    )
    if hasattr(out_ids, "keys"):
        out_ids = out_ids["input_ids"]
    text = tok.apply_chat_template(
        messages, tokenize=False, add_generation_prompt=True, enable_thinking=thinking
    )
    assert tok.encode(text, add_special_tokens=False) == list(out_ids), name
    chat_cases.append({"name": name, "messages": messages, "thinking": thinking, "text": text, "ids": list(out_ids)})

texts = [
    "", " ", "  ", "\n", "\n\n", "\r\n", " \n", "a\n\n b", "hello world", " hello", "hello  world",
    "Hello World!", "HELLO", "don't", "DON'T", "we'll", "I'm", "it's", "'s", "'S", "'ſ", "x'sy",
    "12345", "3.14", "1,000,000", "٣٤٥", "½", "x²", "tab\there", "trailing   ", "   leading",
    "a  \n  b", "a \n\n\n b", "a\r\n\r\nb", "...", "?!", " ?!\n\n", "—", "“quoted”", "é", "Café",
    "東京タワー", "🙂", "👨‍👩‍👧‍👦", "مرحبا بالعالم", SINHALA, "ක්‍රි", "⟦S1⟧", "<|im_end|>", "a<|im_end|>b",
    "<think>\n\n</think>\n\n", "x<think>y", "<|im_start|>assistant\n", "  ", "a　b",
    "email@example.com https://example.com/a?b=c#d", "C++ & Rust's `unsafe` {} [] () <> |",
    "'ſx", "'Sx", "'REx", "'rEx", "'Llx", "'lLx", "'ſt", "x'ſſ", "'Kx", "'Dx", "'Mx", "'VEx", "'Tx",
    "a   b", "a \t b", "a\t\tb", "x  \n", "  \r\n  y", " a", "a\u0085b", " 1", " !x", "!\nx",
    "Ω≈ç√∫˜µ≤≥÷ åß∂ƒ©˙∆˚¬…æ", "ﬁ ﬂ ＡＢＣ", "​‌‍", "à́̂",
]
rng = random.Random(20260930)
alphabet = (
    list("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
    + list(" \t\n\r.,;:!?'\"-_()[]{}<>/\\|@#$%^&*+=~`")
    + ["'s", "'T", "'re", "'VE", "'m", "'ll", "'D", "ſ", " ", "　", " ", "\u0085"]
    + list("ශ්‍රීලංකාවමකැ") + ["‍", "́", "é", "ß", "東", "京", "🙂", "½", "٣", "²", "Ⅻ"]
)
fuzz = ["".join(rng.choice(alphabet) for _ in range(rng.randint(1, 60))) for _ in range(300)]

encode_cases = [{"text": t, "ids": tok.encode(t, add_special_tokens=False)} for t in texts + fuzz[:80]]


def pieces(text):
    return [piece for piece, _ in split.pre_tokenize_str(nfc.normalize_str(text))]


pretokenize_cases = [{"text": t, "pieces": pieces(t)} for t in texts + fuzz]
nfc_cases = [{"text": t, "nfc": nfc.normalize_str(t)} for t in texts + fuzz if nfc.normalize_str(t) != t]

source = {
    "model": f"{MODEL[0]}@{MODEL[1]}",
    "transformers": __import__("transformers").__version__,
    "tokenizers": __import__("tokenizers").__version__,
}
json.dump(
    {"source": source, "chats": chat_cases, "texts": encode_cases},
    open(f"{out}/chat-template.json", "w"), ensure_ascii=False, indent=None, separators=(",", ":"),
)
json.dump(
    {"source": source, "pattern": pattern, "cases": pretokenize_cases, "nfc": nfc_cases},
    open(f"{out}/pretokenize.json", "w"), ensure_ascii=False, indent=None, separators=(",", ":"),
)
print(len(chat_cases), "chats;", len(encode_cases), "texts;", len(pretokenize_cases), "pre-tokenized;", len(nfc_cases), "nfc")
