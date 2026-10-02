#!/usr/bin/env python3
"""Prepare synthetic cleanup inputs and optionally replace them with measured ASR.

Prepare speech seeds, reconcile measured speech-to-text pairs, and score answers by meaning and
required punctuation.
Private dictation history is not a training-data source.
"""

import argparse
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor
import copy
import difflib
import hashlib
import json
import math
from pathlib import Path
import random
import re
import shutil
import subprocess
import sys
import tempfile
import unicodedata

sys.path.insert(0, str(Path(__file__).resolve().parent))
from cleanup_data_rules import TOKEN, canonical, carry_optional_commas, reconcile, units
import cleanup_scoring


ROOT = Path(__file__).resolve().parent.parent
TRAINING = ROOT / "Packages/LiveTranscribeKit/Training"
SPLITS = ("train", "valid", "test")
PROFILES = ("original", "missing-separators", "changed-separators", "lowercase")
PROTECTED = re.compile(
    r"⟦[^⟧]+⟧|\b[STU]\d+\b|https?://[^\s]+|www\.[^\s]+|"
    r"[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}|`[^`]+`|"
    r"\b\d+(?:[.,:/\-]\d+)+\b|\b(?:[A-Za-z]\.){2,}"
)
PLACEHOLDER = re.compile(r"⟦[^⟧]+⟧|\b[STU]\d+\b")
RULES = TRAINING / "speech-to-text-rules.json"
# How measured inputs are also given in train and valid, as other recognizers write them.
INPUT_VARIANTS = ("unpunctuated", "lowercase", "odd-stops", "odd-case")
# Share of the seed dictations that can be joined which are, in train and valid.
COMPOSITE_SHARE = 0.6
# Words a joined dictation may have; Deep's training checks allow 90 after fillers are removed.
COMPOSITE_MAX_WORDS = 80
# Words a recognizer doesn't take for a name, so odd capitals leave them alone.
FUNCTION_WORDS = {
    "the", "and", "for", "but", "you", "are", "was", "were", "his", "her", "its", "our", "not",
    "has", "had", "can", "may", "all", "any", "too", "with", "that", "this", "from", "they",
    "them", "then", "than", "have", "will", "just", "into", "been", "what", "when", "your",
    "about", "she", "him", "who", "how", "why", "did", "does", "out", "off", "own", "very",
}
# Words a pause, and so a full stop speech-to-text writes, often comes before.
CLAUSE_WORDS = {"and", "but", "so", "or", "because", "then", "which", "when", "if", "actually", "sorry"}
# Words no one pauses after as if a sentence ended.
NEVER_LAST = {
    "a", "an", "the", "to", "of", "in", "on", "at", "for", "with", "from", "by", "into", "about",
    "my", "your", "our", "their", "his", "her", "its", "is", "are", "was", "were", "will", "would",
    "can", "could", "should", "have", "has", "had", "do", "does", "did", "be", "and", "but", "or",
    "so", "because", "if", "that", "which", "when", "i", "we", "they", "you", "he", "she", "very",
    "just", "not", "i'll", "i'm", "we'll", "we're", "it's", "let's", "before", "after", "than",
    "as", "some", "any", "this", "these", "those", "every", "each", "no", "until", "like",
    "through", "over", "under", "between", "both", "either", "more", "most", "such", "other",
    "another", "what", "where", "who", "whose", "how", "why", "whether",
}


def policy_for(options):
    path = getattr(options, "rules", RULES)
    return json.loads(path.read_text()), path


def digest(value):
    data = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(data.encode()).hexdigest()


def file_digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def normalize(text):
    """The word comparison used by Shared.EditDistance, including apostrophes."""
    chars = []
    for char in text.lower().replace("’", "'"):
        if char in "-—–":
            chars.append(" ")
        elif char == "'" or unicodedata.category(char)[0] not in "PS":
            chars.append(char)
    return " ".join(word.strip("'") for word in "".join(chars).split() if word.strip("'"))


def read_rows(path, with_line_numbers=False):
    rows = []
    for line_number, line in enumerate(path.read_text().splitlines(), 1):
        if not line.strip():
            continue
        try:
            row = json.loads(line)
            if not isinstance(row, dict):
                raise ValueError("an example must be an object")
            if "rawText" in row or "cleanedText" in row:
                raise ValueError("private dictation history is evaluation-only; do not prepare it for training")
            rows.append((line_number, row) if with_line_numbers else row)
        except (ValueError, TypeError) as error:
            raise ValueError(f"{path}:{line_number}: {error}") from error
    return rows


def write_rows(path, rows):
    path.parent.mkdir(parents=True, exist_ok=True)
    text = "".join(json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n" for row in rows)
    path.write_text(text)


def check_example(row):
    for field in ("raw", "target", "category"):
        if not isinstance(row.get(field), str) or not row[field].strip():
            raise ValueError(f"missing or empty {field}")
    if not isinstance(row.get("context", []), list) or not all(
        isinstance(line, str) and line.strip() for line in row.get("context", [])
    ):
        raise ValueError("context must contain nonempty strings")
    for flag in ("multiline", "letterBody"):
        if flag in row and not isinstance(row[flag], bool):
            raise ValueError(f"{flag} must be a boolean")


def _free_words(text):
    """The words of ``text`` as matches, each with whether it lies clear of protected values."""
    protected = [match.span() for match in PROTECTED.finditer(text)]
    return [(match, not any(start < match.end() and match.start() < end for start, end in protected))
            for match in re.finditer(r"\S+", text)]


def _sentence_positions(words):
    """For each word, how many words of its sentence come before it and after it."""
    before, after, count = [], [0] * len(words), 0
    for match, _ in words:
        before.append(count)
        count = 0 if re.search(r"[.?!][\"'”’)\]]*$", match.group()) else count + 1
    count = 0
    for index in range(len(words) - 1, -1, -1):
        if re.search(r"[.?!][\"'”’)\]]*$", words[index][0].group()):
            count = 0
        after[index] = count
        count += 1
    return before, after


def _swap_case(word):
    """``word`` with its first letter's case changed."""
    index = next(index for index, char in enumerate(word) if char.isalpha())
    return word[:index] + word[index].swapcase() + word[index + 1:]


def _edit(text, edits):
    for start, end, replacement in sorted(edits, reverse=True):
        text = text[:start] + replacement + text[end:]
    return text


def _odd_stops(text, rng):
    """A full stop where a recognizer heard a pause, and a capital after it, as it writes them."""
    words = _free_words(text)
    before, after = _sentence_positions(words)
    choices, weights = [], []
    for index in range(len(words) - 1):
        (word, free), (following, next_free) = words[index], words[index + 1]
        if (not free or not next_free or "\n" in text[word.end():following.start()]
                or not re.search(r"[\w,]$", word.group()) or not following.group()[:1].isalpha()
                or word.group().rstrip(",").lower() in NEVER_LAST or before[index] < 1 or after[index] < 2):
            continue
        choices.append(index)
        weights.append(4 if word.group().endswith(",") else 3 if following.group().lower() in CLAUSE_WORDS else 1)
    edits = []
    for _ in range(1 + (len(choices) >= 4 and rng.random() < 0.35)):
        if not any(weights):
            break
        index = rng.choices(choices, weights=weights)[0]
        # No sentence of one word: a second stop stays two words away.
        weights = [0 if abs(choice - index) <= 2 else weight for choice, weight in zip(choices, weights)]
        word, following = words[index][0], words[index + 1][0]
        comma = word.group().endswith(",")
        edits.append((word.end() - comma, word.end(), "."))
        if following.group()[:1].islower():
            edits.append((following.start(), following.end(), _swap_case(following.group())))
    return _edit(text, edits)


def _odd_case(text, rng):
    """Capitals where a recognizer guessed wrong: a common word taken for a name, a sentence or
    a name begun in lower case."""
    words = _free_words(text)
    before, _ = _sentence_positions(words)
    choices = []
    for index, (word, free) in enumerate(words):
        core = word.group().strip("\"'“”‘’()[],.?!:;…")
        if not free or not core.isalpha():
            continue
        if core.islower() and before[index] > 0 and len(core) > 2 and core not in FUNCTION_WORDS:
            choices.append(index)
        elif core[:1].isupper() and not core[1:].isupper() and core != "I":
            choices.append(index)
    count = min(len(choices), 1 + (rng.random() < 0.5) + (rng.random() < 0.25))
    return _edit(text, [(words[index][0].start(), words[index][0].end(), _swap_case(words[index][0].group()))
                        for index in rng.sample(choices, count)])


def transform(text, profile, seed=None):
    """``text`` as one kind of input writes it, its words and protected values unchanged.

    ``odd-stops`` and ``odd-case`` choose where by ``seed``, so a dataset is reproducible."""
    if profile in ("odd-stops", "odd-case"):
        result = (_odd_stops if profile == "odd-stops" else _odd_case)(text, random.Random(seed))
        if normalize(result) != normalize(text):
            raise ValueError("augmentation changed words")
        return result

    def unprotected(part):
        if profile == "missing-separators":
            return part.translate(str.maketrans("", "", ",:;"))
        if profile == "changed-separators":
            return part.translate(str.maketrans({",": ".", ":": ",", ";": ","}))
        if profile == "lowercase":
            return part.lower()
        if profile == "unpunctuated":
            # As a recognizer that writes no punctuation does: lower case, no marks between words.
            return re.sub(r"[.,?!:;…]+(?=\s|$)|(?:^|(?<=\s))[.,?!:;…]+", "", re.sub(r"[—–]", " ", part.lower()))
        if profile != "original":
            raise ValueError(f"unknown profile: {profile}")
        return part

    pieces, cursor = [], 0
    for match in PROTECTED.finditer(text):
        pieces.extend((unprotected(text[cursor:match.start()]), match.group()))
        cursor = match.end()
    pieces.append(unprotected(text[cursor:]))
    result = "".join(pieces)
    if profile == "unpunctuated":
        result = re.sub(r"[ \t]{2,}", " ", result).strip()
    if normalize(result) != normalize(text):
        raise ValueError("augmentation changed words")
    return result


ENDS_SENTENCE = re.compile(r"[.?!][\"'”’)\]]*$")


def composable(row):
    """Whether a seed dictation can be one of several said one after another: sentences in one
    paragraph, with no context, letter body or post-command token, ending as a sentence does.
    Recognition seeds stay apart, as written ("the knew laptop"): spoken, the recognizer writes
    the right word, so they train as written (``--include-synthetic-category``)."""
    return (row["profile"] == "original" and not row.get("context") and not row.get("letterBody")
            and "\n" not in row["raw"] and "\n" not in row["target"] and row["category"] != "recognition"
            and not PLACEHOLDER.search(row["raw"]) and not PLACEHOLDER.search(row["target"])
            and ENDS_SENTENCE.search(row["target"].strip()) is not None)


def said_in_composite(raw):
    """A seed dictation as a composite says it: ending as a sentence does."""
    raw = raw.strip()
    return raw if ENDS_SENTENCE.search(raw) else raw + "."


# What a composite keeps of each part, to give the parts back if the composite can't be used.
PART_FIELDS = ("id", "family_id", "category", "raw", "target", "training_weight", "provenance")


def composite(parts, split):
    """One dictation of ``parts`` said one after another, each answered as on its own."""
    raw = " ".join(said_in_composite(part["raw"]) for part in parts)
    target = " ".join(part["target"].strip() for part in parts)
    multiline = parts[0].get("multiline", False)
    family = digest({"raw": normalize(raw), "target": target, "context": [], "multiline": multiline, "letterBody": False})[:24]
    return {"raw": raw, "target": target, "category": "composite", "context": [], "multiline": multiline,
            "letterBody": False, "id": f"{family}-{digest(raw)[:12]}", "family_id": family, "split": split,
            "profile": "original", "training_weight": max(part.get("training_weight", 1) for part in parts),
            "source": f"composite:{split}:{len(parts)}", "source_categories": [part["category"] for part in parts],
            "provenance": {"kind": "composite",
                           "parts": [{field: part[field] for field in PART_FIELDS if field in part} for part in parts]}}


def composite_parts(original, observed, policy):
    """Each part of a composite with the words the recognizer wrote for it, cut where the parts
    meet: before the next part's first word, or after this one's last word with what follows it,
    whichever the recognizer wrote as said. A part is left out when it wrote neither, since then
    no one can say where it ends."""
    parts = original["provenance"]["parts"]
    pieces = [said_in_composite(part["raw"]) for part in parts]
    said = units(original["raw"], policy)
    piece_units = [units(piece, policy) for piece in pieces]
    if [unit.key for unit in said] != [unit.key for found in piece_units for unit in found]:
        return []
    heard = units(observed, policy)
    matcher = difflib.SequenceMatcher(a=[unit.key for unit in said], b=[unit.key for unit in heard], autojunk=False)
    position = {block.a + offset: block.b + offset for block in matcher.get_matching_blocks() for offset in range(block.size)}
    cuts, start = [0], 0
    for found in piece_units[:-1]:
        start += len(found)
        before, after = position.get(start - 1), position.get(start)
        if after is not None:
            cut = heard[after].start
            # A quote or bracket the next part opens with goes with it.
            while cut > 0 and observed[cut - 1] in "\"'“‘([":
                cut -= 1
            cuts.append(cut)
        elif before is not None:
            cut = heard[before].end
            while cut < len(observed) and not observed[cut].isspace():
                cut += 1
            cuts.append(cut)
        else:
            cuts.append(None)
    cuts.append(len(observed))
    return [(part, piece, observed[begin:end].strip())
            for part, piece, begin, end in zip(parts, pieces, cuts, cuts[1:])
            if begin is not None and end is not None and observed[begin:end].strip()]


def compose(data, share):
    """Join seed dictations two to four at a time, in a field of one kind, up to
    COMPOSITE_MAX_WORDS words, so the adapter reads text as long as people dictate.

    ``share`` of the rows that can be joined are, chosen by digest. In train and valid the rows
    joined leave the split, so each is trained on once; the test split keeps them, so they stay
    measured on their own as before, and adds the joined ones."""
    counts = {}
    for split in SPLITS:
        groups = defaultdict(list)
        for row in data[split]:
            if composable(row):
                groups[row.get("multiline", False)].append(row)
        joined, used = [], set()
        for _, rows in sorted(groups.items()):
            rows.sort(key=lambda row: digest(["composite", row["family_id"], row["id"]]))
            pool = rows[:math.floor(len(rows) * share)]
            cursor = 0
            while cursor < len(pool):
                size = 2 + int(digest(["composite-size", pool[cursor]["id"]])[:8], 16) % 3
                parts, words = [pool[cursor]], len(normalize(pool[cursor]["raw"]).split())
                cursor += 1
                while len(parts) < size and cursor < len(pool):
                    more = len(normalize(pool[cursor]["raw"]).split())
                    if words + more > COMPOSITE_MAX_WORDS:
                        break
                    parts.append(pool[cursor])
                    words += more
                    cursor += 1
                if len(parts) > 1:
                    joined.append(composite(parts, split))
                    used.update(part["id"] for part in parts)
        if split != "test":
            data[split] = [row for row in data[split] if row["id"] not in used]
        data[split].extend(joined)
        counts[split] = {"composites": len(joined), "parts": len(used)}
    return counts


def check_splits(data, held_out=()):
    families, inputs, ids = {}, {}, set()
    held_out = set(held_out)
    for split in SPLITS:
        for row in data[split]:
            check_example(row)
            identity = row.get("id")
            if identity:
                if identity in ids:
                    raise ValueError(f"duplicate example id: {identity}")
                ids.add(identity)
            family = row.get("family_id")
            if family:
                previous = families.setdefault(family, split)
                if previous != split:
                    raise ValueError(f"one source family occurs in {previous} and {split}: {family}")
            raw = normalize(row["raw"])
            previous = inputs.setdefault(raw, split)
            if previous != split:
                raise ValueError(f"the same normalized input occurs in {previous} and {split}")
            if split != "test" and raw in held_out:
                raise ValueError(f"a {split} input also occurs in the held-out evaluation files")
            if row.get("split", split) != split:
                raise ValueError(f"wrong split metadata in {split}")


def report(data, extra=None):
    result = {"schema_version": 1, "stage": "candidate-data", "splits": {}}
    for split, rows in data.items():
        word_count = sum(len(TOKEN.findall(row["raw"])) for row in rows)
        result["splits"][split] = {
            "examples": len(rows),
            "families": len({row["family_id"] for row in rows}),
            "categories": dict(sorted(Counter(row["category"] for row in rows).items())),
            "profiles": dict(sorted(Counter(row["profile"] for row in rows).items())),
            "colon_inputs": sum(":" in row["raw"] for row in rows),
            "question_inputs": sum("?" in row["raw"] for row in rows),
            "review_required": sum(row.get("review_required", False) for row in rows),
            "training_weighted_examples": sum(row.get("training_weight", 1) for row in rows),
            "capital_start_inputs": sum(row["raw"].strip()[:1].isupper() for row in rows),
            "lowercase_start_inputs": sum(row["raw"].strip()[:1].islower() for row in rows),
            "mean_words": round(word_count / max(1, len(rows)), 2),
            "commas_per_100_words": round(100 * sum(row["raw"].count(",") for row in rows) / max(1, word_count), 3),
            "colons_per_100_words": round(100 * sum(row["raw"].count(":") for row in rows) / max(1, word_count), 3),
        }
    result.update(extra or {})
    return result


def save_dataset(output, data, metadata):
    check_splits(data)
    output.mkdir(parents=True, exist_ok=True)
    for split in SPLITS:
        write_rows(output / f"{split}.jsonl", data[split])
    (output / "preparation-report.json").write_text(
        json.dumps(report(data, metadata), ensure_ascii=False, sort_keys=True, indent=2) + "\n"
    )


def prepare(options):
    policy, policy_path = policy_for(options)
    stress = getattr(options, "stress_profiles", False)
    profiles = PROFILES if stress else ("original",)
    prefix = "deep-" if options.kind == "deep" else ""
    data = {split: [] for split in SPLITS}
    sources = []
    excluded = set()
    held_out_files = sorted((TRAINING / "eval").glob("*.jsonl")) if options.kind == "deep" else []
    held_out_files += sorted((TRAINING / "curated/test").glob("*.jsonl"))
    if options.kind == "deep" and (options.input_dir / "test.jsonl").exists():
        held_out_files.append(options.input_dir / "test.jsonl")
    for path in held_out_files:
        excluded.update(normalize(row["raw"]) for row in read_rows(path))
    for split in SPLITS:
        paths = [options.input_dir / f"{prefix}{split}.jsonl"]
        if options.kind == "medium" and split in ("train", "test"):
            paths += sorted((TRAINING / f"curated/{split}").glob("*.jsonl"))
        for path in paths:
            sources.append({"path": str(path.resolve()), "sha256": file_digest(path)})
            for line_number, original in read_rows(path, with_line_numbers=True):
                check_example(original)
                family = digest({
                    "raw": normalize(original["raw"]), "target": original["target"],
                    "context": original.get("context", []),
                    "multiline": original.get("multiline", False),
                    "letterBody": original.get("letterBody", False),
                })[:24]
                seen = set()
                for profile in profiles:
                    raw = transform(original["raw"], profile)
                    if raw in seen:
                        continue
                    seen.add(raw)
                    row = copy.deepcopy(original)
                    row.update({
                        "raw": raw, "id": f"{family}-{digest(raw)[:12]}",
                        "family_id": family, "split": split, "profile": profile,
                        "training_weight": 2 if split == "train" and path.parent.parent.name == "curated" else 1,
                        "source": f"prepared:{path.name}:{line_number}:{profile}",
                        "provenance": {"file": path.name, "line": line_number,
                                       "source": original.get("source", ""), "kind": "synthetic"},
                    })
                    data[split].append(row)
    share = getattr(options, "composite_share", COMPOSITE_SHARE) if options.kind == "deep" and not stress else 0
    # The rows joined leave train and valid, so they are checked against the held-out files first.
    check_splits(data, excluded)
    composites = compose(data, share) if share else {}
    if options.kind == "deep" and options.input_dir.resolve() == (TRAINING / "generated").resolve():
        for split in SPLITS:
            for index, seed in enumerate(policy.get("context_seeds", {}).get(split, []), 1):
                row = dict(seed, category=seed.get("category", "recognition"), context=[], multiline=False, letterBody=False)
                family = digest({"raw": normalize(row["raw"]), "target": row["target"], "context": [],
                                 "multiline": False, "letterBody": False})[:24]
                row.update(id=f"{family}-{digest(row['raw'])[:12]}", family_id=family, split=split,
                           profile="original", training_weight=1, source=f"phonetic-context:{split}:{index}",
                           provenance={"kind": "synthetic-context", "file": policy_path.name, "case": index})
                data[split].append(row)
    check_splits(data, excluded)
    save_dataset(options.output, data, {"kind": options.kind, "stage": "stress-data" if stress else "speech-seeds",
                                      "profiles": list(profiles), "sources": sources,
                                      "composite_share": share, "composites": composites,
                                      "rules_sha256": file_digest(policy_path), "curated_train_weight": 2})
    print(json.dumps({"output": str(options.output), "splits": {k: len(v) for k, v in data.items()}}))


def read_dataset(directory):
    data = {split: read_rows(directory / f"{split}.jsonl") for split in SPLITS}
    check_splits(data)
    return data


def select_audio(data, limit):
    groups = defaultdict(list)
    skipped = 0
    for split, rows in data.items():
        for row in rows:
            if row["profile"] != "original":
                continue
            if PLACEHOLDER.search(row["raw"]) or PLACEHOLDER.search(row["target"]):
                skipped += 1
                continue  # These are post-command LLM tokens, not words to synthesize.
            groups[(split, row["category"])].append(row)
    for rows in groups.values():
        rows.sort(key=lambda row: digest(row["family_id"]))
    selected = []
    while groups and len(selected) < limit:
        # Interleave splits within each category even for a small pilot.
        for key in sorted(list(groups), key=lambda key: (key[1], SPLITS.index(key[0]))):
            selected.append(groups[key].pop(0))
            if not groups[key]:
                del groups[key]
            if len(selected) == limit:
                break
    return selected, skipped


def audio(options):
    if not shutil.which("say") or not shutil.which("afconvert"):
        raise ValueError("audio generation needs macOS say and afconvert")
    data = read_dataset(options.dataset)
    limit = sum(len(rows) for rows in data.values()) if getattr(options, "all", False) else options.limit
    selected, skipped = select_audio(data, limit)
    options.output.mkdir(parents=True, exist_ok=True)
    done = 0

    def synthesize(row, scratch):
        nonlocal done
        spoken = " ".join(row["raw"].split())
        clip_id = digest({"family": row["family_id"], "spoken": spoken,
                          "voice": options.voice, "rate": options.rate})[:24]
        wav_file = options.output / f"{clip_id}.wav"
        # A clip is written under another name and renamed when complete, so one that exists
        # from an interrupted run is whole and is kept.
        if not wav_file.exists():
            text_file = Path(scratch) / f"{clip_id}.txt"
            aiff_file = Path(scratch) / f"{clip_id}.aiff"
            partial = options.output / f".{clip_id}.wav.partial"
            text_file.write_text(spoken)
            subprocess.run(["say", "-v", options.voice, "-r", str(options.rate),
                            "-f", str(text_file), "-o", str(aiff_file)], check=True, capture_output=True)
            subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1",
                            str(aiff_file), str(partial)], check=True, capture_output=True)
            partial.replace(wav_file)
            aiff_file.unlink()
            text_file.unlink()
        done += 1
        if done % 100 == 0:
            print(f"Synthesized {done}/{len(selected)} clips", flush=True)
        target = row["target"].replace("\n", "\\n").replace("\t", " ")
        return ({"id": clip_id, "example": row, "spoken": spoken,
                 "audio_sha256": file_digest(wav_file),
                 "tts": {"voice": options.voice, "rate": options.rate, "sample_rate": 16000}},
                "\t".join((clip_id, row["category"], spoken, target)))

    with tempfile.TemporaryDirectory(prefix="lt-cleanup-tts-") as scratch:
        with ThreadPoolExecutor(max_workers=options.jobs) as pool:
            clips = list(pool.map(lambda row: synthesize(row, scratch), selected))
    manifest = [clip for clip, _ in clips]
    table = [line for _, line in clips]
    write_rows(options.output / "audio-manifest.jsonl", manifest)
    (options.output / "clips.tsv").write_text("\n".join(table) + "\n")
    print(json.dumps({"clips": len(manifest), "placeholder_families_not_spoken": skipped,
                      "output": str(options.output)}))


def measure(original, spoken, observed, transcript, clip, policy, source_report, part=None):
    """``original`` as the recognizer wrote ``spoken``: its measured input and reconciled target."""
    row = copy.deepcopy(original)
    target, reconciliation = reconcile(original, spoken, observed, policy)
    suffix = "" if part is None else f":{part}"
    row.update({"raw": observed, "profile": "measured-asr",
                "target": target, "reconciliation": reconciliation,
                "id": f"{original['family_id']}-asr-{digest([transcript, part] if part is not None else transcript)[:12]}",
                "source": f"asr:{digest(transcript['model'])[:12]}:{clip['id']}{suffix}",
                "review_required": bool(reconciliation["unresolved"]),
                "provenance": {"kind": "tts-asr", "tts": clip["tts"],
                               "model": transcript["model"],
                               "model_config_sha256": transcript["model_config_sha256"],
                               "model_weights_sha256": transcript["model_weights_sha256"],
                               "language": transcript.get("language", "auto"),
                               "audio_sha256": clip["audio_sha256"], "clip_id": clip["id"],
                               "seed": original.get("provenance")}})
    # A category that keeps every word can't also fix one; a list kept on one line is such.
    keeps_words = original["category"] in ("facts", "unchanged", "series") or (
        original["category"] in ("list-two", "list-many") and "\n" not in target)
    if source_report.get("kind") == "deep" and keeps_words and any(
        change["rule"] == "sound-alike-retain-target" for change in reconciliation["changes"]
    ):
        row.update(category="recognition", source_category=original["category"])
    return row


def merge_asr(options):
    policy, policy_path = policy_for(options)
    source_data = read_dataset(options.dataset)
    source_report = json.loads((options.dataset / "preparation-report.json").read_text())
    data = source_data if options.include_synthetic else {split: [] for split in SPLITS}
    # A word fix planted in writing ("the knew laptop") doesn't survive speech, since the
    # recognizer writes the word it hears, so a category named here keeps its synthetic rows in
    # training and validation. The held-out test stays measured.
    synthetic_categories = sorted(set(getattr(options, "include_synthetic_category", None) or []))
    if not options.include_synthetic:
        for split in ("train", "valid"):
            data[split].extend(copy.deepcopy(row) for row in source_data[split] if row["category"] in synthetic_categories)
    audio_rows = read_rows(options.audio_manifest)
    clips = {row["id"]: row for row in audio_rows}
    if len(clips) != len(audio_rows):
        raise ValueError("duplicate clip ids in audio manifest")
    # A family may hold one sentence more than once, cased and lowercase, as Medium's examples do.
    families = defaultdict(list)
    for rows in source_data.values():
        for row in rows:
            if row["profile"] == "original":
                families[row["family_id"]].append(row)
    models = []
    transcripts = []
    excluded = []
    for path in options.transcripts:
        rows = read_rows(path)
        if len({row.get("id") for row in rows}) != len(rows):
            raise ValueError(f"duplicate transcript ids in {path}")
        if {row.get("id") for row in rows} != set(clips):
            raise ValueError(f"{path} must contain exactly the audio manifest's clip ids")
        identities = {(row.get("model"), row.get("model_config_sha256"), row.get("model_weights_sha256"), row.get("language", "auto")) for row in rows}
        if len(identities) != 1 or not all(all(identity) for identity in identities):
            raise ValueError(f"{path} needs one recorded model identity, config/weights hashes and language")
        models.extend(sorted(identities))
        transcripts.append({"path": str(path.resolve()), "sha256": file_digest(path)})
        for transcript in rows:
            clip = clips[transcript["id"]]
            if transcript.get("audio_sha256") != clip["audio_sha256"]:
                raise ValueError(f"stale or different audio for clip {clip['id']}")
            original = clip["example"]
            if original not in families.get(original["family_id"], []):
                raise ValueError("audio was generated from a different dataset")
            if not isinstance(transcript.get("raw"), str) or not transcript["raw"].strip():
                raise ValueError(f"empty ASR transcript for clip {clip['id']}")
            measured = [measure(original, clip["spoken"], transcript["raw"], transcript, clip, policy, source_report)]
            # A composite that needs review gives back its parts, each with the words the
            # recognizer wrote for it, so one misheard word costs one sentence, as said alone.
            # The test split keeps its parts as they were measured on their own.
            if measured[0]["review_required"] and original["category"] == "composite" and original["split"] != "test":
                for part, spoken, heard in composite_parts(original, transcript["raw"], policy):
                    seed = dict(part, context=[], multiline=original["multiline"], letterBody=False,
                                split=original["split"], profile="original")
                    seed.setdefault("training_weight", original.get("training_weight", 1))
                    row = measure(seed, spoken, heard, transcript, clip, policy, source_report, part=part["id"])
                    row["provenance"]["composite_id"] = original["id"]
                    measured.append(row)
            for row in measured:
                if row["reconciliation"]["exclude_reason"]:
                    excluded.append(row)
                else:
                    data[row["split"]].append(row)

    # Rehearse post-command tokens at their source-family rate, including in small pilots.
    # At full size this restores every placeholder family (800 in the original Deep train set).
    for split in SPLITS:
        originals = [row for row in source_data[split] if row["profile"] == "original"]
        placeholders = [row for row in originals if PLACEHOLDER.search(row["raw"])]
        selected_families = {clip["example"]["family_id"] for clip in clips.values() if clip["example"]["split"] == split}
        count = min(len(placeholders), math.ceil(len(selected_families) * len(placeholders) / max(1, len(originals) - len(placeholders))))
        for original in sorted(placeholders, key=lambda row: digest(row["family_id"]))[:count]:
            row = copy.deepcopy(original)
            row.update(id=f"{row['family_id']}-placeholder", profile="placeholder-rehearsal",
                       review_required=False, training_weight=original.get("training_weight", 1) * len(models) if split == "train" else 1)
            data[split].append(row)

    # Transcripts as the recognizer writes them, for what a voice can't carry through TTS: a common
    # word it writes as a name ("We need to Harry" for hurry) or letters it spells out ("B B C").
    # The rules file holds each template's seeds in one split, so the test's are sentences unseen.
    transcript_seeds = getattr(options, "include_transcript_seeds", False)
    for split in SPLITS if transcript_seeds else ():
        for index, seed in enumerate(policy.get("transcript_seeds", {}).get(split, []), 1):
            row = dict(seed, category=seed.get("category", "recognition"), context=[],
                       multiline=seed.get("multiline", False), letterBody=False)
            family = digest({"raw": normalize(row["raw"]), "target": row["target"], "context": [],
                             "multiline": row["multiline"], "letterBody": False})[:24]
            row.update(id=f"{family}-{digest(row['raw'])[:12]}", family_id=family, split=split,
                       profile="transcript-seed", training_weight=1, review_required=False,
                       source=f"transcript-seed:{split}:{index}",
                       provenance={"kind": "synthetic-transcript", "file": policy_path.name, "case": index})
            data[split].append(row)

    phonetic_rate = getattr(options, "sound_alike_rate", 0.1) if source_report.get("kind") == "deep" else 0
    known_names = {name.lower() for name in policy.get("names", [])}
    eligible = []
    for split in SPLITS:
        for original in data[split]:
            if original["profile"] != "measured-asr" or original["review_required"]:
                continue
            if original["category"] not in ("facts", "unchanged", "series"):
                continue
            if canonical(original["raw"], policy) != canonical(original["target"], policy):
                continue
            for unit in units(original["raw"], policy):
                if unit.key in known_names:
                    continue
                group = next((g for g in policy["sound_alikes"] if unit.key in g), None)
                if group is None:
                    continue
                eligible.append((split, original, unit, group))
                break
    # Choose whole families before expansion across recognizers; enforce the configured cap.
    eligible_families = sorted({row["family_id"] for _, row, _, _ in eligible}, key=digest)
    chosen = set(eligible_families[:math.floor(len(eligible_families) * phonetic_rate)])
    for split, original, unit, group in eligible:
        if original["family_id"] not in chosen:
            continue
        replacement = next(value for value in group if value != unit.key)
        if unit.text[:1].isupper():
            replacement = replacement[:1].upper() + replacement[1:]
        row = copy.deepcopy(original)
        row.update(raw=original["raw"][:unit.start] + replacement + original["raw"][unit.end:],
                   id=original["id"] + "-sound-alike", category="recognition", profile="sound-alike",
                   provenance={"kind": "synthetic-sound-alike", "parent_id": original["id"],
                               "from": unit.text, "to": replacement, "rules_sha256": file_digest(policy_path)})
        data[split].append(row)

    # Cleanup must not depend on the punctuation or capitals a recognizer guesses. Some write none,
    # some only lower case, some a full stop at every pause, and some capitalise a word they take
    # for a name, so a share of measured families in train and valid also comes in each such form,
    # with the same answer. The words are still the recognizer's; the held-out test stays as it
    # was measured.
    variants = dict(getattr(options, "input_variant", None) or []) if source_report.get("kind") == "deep" else {}
    measured_families = sorted({row["family_id"] for split in ("train", "valid") for row in data[split]
                                if row["profile"] == "measured-asr" and not row["review_required"]})
    variant_rows = Counter()
    for kind, rate in sorted(variants.items()):
        ranked = sorted(measured_families, key=lambda family: digest([kind, family]))
        chosen = set(ranked[:math.floor(len(ranked) * rate)])
        for split in ("train", "valid"):
            inputs = {row["raw"] for row in data[split]}
            for original in list(data[split]):
                if (original["profile"] != "measured-asr" or original["review_required"]
                        or original["family_id"] not in chosen):
                    continue
                raw = transform(original["raw"], kind, seed=digest([kind, original["id"]]))
                if raw in inputs:
                    continue
                inputs.add(raw)
                row = copy.deepcopy(original)
                row.update(raw=raw, id=f"{original['id']}-{kind}", profile=kind,
                           provenance={"kind": f"derived-{kind}", "parent_id": original["id"]})
                data[split].append(row)
                variant_rows[kind] += 1

    # Optional punctuation follows the input each answer is given: a comma English leaves to the
    # writer stays where the input has one and goes where it has none, so the adapter learns no
    # house style, the generator's included. Required punctuation is the target's.
    carried = Counter()
    for split in SPLITS:
        for row in data[split]:
            if row.get("review_required"):
                continue
            target = carry_optional_commas(row["target"], row["raw"])
            if target != row["target"]:
                row.update(target=target, target_before_optional_commas=row["target"])
                carried[split] += 1
    save_dataset(options.output, data, {"stage": "candidate-data", "asr_models": models,
                                      "kind": source_report.get("kind"), "excluded_pairs": len(excluded),
                                      "sound_alike_rate": phonetic_rate, "input_variants": variants,
                                      "input_variant_rows": dict(sorted(variant_rows.items())),
                                      "optional_commas_carried": dict(carried),
                                      "rules_sha256": file_digest(policy_path),
                                      "includes_synthetic": options.include_synthetic,
                                      "synthetic_categories": synthetic_categories,
                                      "transcript_seeds": transcript_seeds,
                                      "source_dataset_sha256": {split: file_digest(options.dataset / f"{split}.jsonl") for split in SPLITS},
                                      "transcripts": transcripts,
                                      "audio_manifest_sha256": file_digest(options.audio_manifest)})
    write_rows(options.output / "excluded.jsonl", excluded)
    print(json.dumps({"output": str(options.output), "asr_rows": len(clips) * len(options.transcripts),
                      "excluded_pairs": len(excluded), "candidate_rows": sum(map(len, data.values())),
                      "review_required": sum(row.get("review_required", False) for rows in data.values() for row in rows)}))


# Audit reasons that show a fault in the preparation itself, which a quarantine must not hide.
# Every other reason is about one pair: a target the checks turn down, one that needs review, or
# an input held out or seen in another split.
STRUCTURAL = (
    "duplicate example id",
    "missing id",
    "missing family_id",
    "source family also occurs in",
    "wrong split metadata",
    "training_weight must be",
)


DERIVED = "derived from a quarantined row, whose target it shares"


def quarantine(options):
    """Move the rows an audit blocked into quarantined.jsonl, with the audit's reasons.

    A row derived from one set aside (a variant of its input, or a sound-alike planted in it) goes
    too, though its own input may pass: it shares the target the audit turned down."""
    audit = json.loads(options.audit.read_text())
    for name, expected in audit["files"].items():
        if file_digest(options.dataset / name) != expected:
            raise ValueError(f"{name} changed since the audit; audit it again first")
    blocked = defaultdict(dict)
    for issue in audit["issues"]:
        path = Path(issue["file"])
        if path.parent.resolve() != options.dataset.resolve() or path.stem not in SPLITS or issue["line"] < 1:
            raise ValueError(f"not a row of this dataset: {issue}")
        structural = [reason for reason in issue["reasons"] if reason.startswith(STRUCTURAL)]
        if structural:
            raise ValueError(f"{path.name}:{issue['line']} has a preparation fault: {structural}")
        blocked[path.stem][issue["line"]] = issue["reasons"]
    lines = {split: (options.dataset / f"{split}.jsonl").read_text().splitlines() for split in SPLITS}
    rows = {split: {number: json.loads(line) for number, line in enumerate(lines[split], 1) if line.strip()}
            for split in SPLITS}
    held_ids = {rows[split][number]["id"] for split in SPLITS for number in blocked[split]}
    while True:
        derived = [(split, number) for split in SPLITS for number, row in rows[split].items()
                   if number not in blocked[split] and row.get("provenance", {}).get("parent_id") in held_ids]
        if not derived:
            break
        for split, number in derived:
            blocked[split][number] = [DERIVED]
            held_ids.add(rows[split][number]["id"])
    held, reasons = [], Counter()
    for split in SPLITS:
        kept = []
        for number, line in enumerate(lines[split], 1):
            if number in blocked[split]:
                held.append({"split": split, "reasons": blocked[split][number], "row": rows[split][number]})
                reasons.update(blocked[split][number])
            elif line.strip():
                kept.append(line)
        (options.dataset / f"{split}.jsonl").write_text("".join(line + "\n" for line in kept))
    write_rows(options.dataset / "quarantined.jsonl", held)
    report_file = options.dataset / "preparation-report.json"
    report = json.loads(report_file.read_text())
    report["quarantine"] = {"audit_sha256": file_digest(options.audit), "rows": len(held),
                            "by_split": dict(Counter(row["split"] for row in held)),
                            "reasons": dict(reasons.most_common())}
    report_file.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(json.dumps(report["quarantine"]))


def score(options):
    data = read_rows(options.data)
    if any(row.get("review_required") for row in data):
        raise ValueError("resolve or quarantine review-required held-out pairs before scoring")
    expected_ids = {row["id"] for row in data}
    measurements = json.loads(options.measurements.read_text())
    rows = measurements["results"]
    if len(expected_ids) != len(data) or len({row["id"] for row in rows}) != len(rows) or {row["id"] for row in rows} != expected_ids:
        raise ValueError("scoring needs exactly one result for every held-out example id")
    sources = {row["id"]: row for row in data}
    scored = []
    for row in rows:
        source = sources[row["id"]]
        if row["raw"] != source["raw"] or row["target"] != source["target"]:
            raise ValueError("measurement inputs do not match the held-out dataset")
        scored.append({"id": row["id"], "category": row["category"],
                       **cleanup_scoring.score_case(row["shown"], source["target"], source.get("alternatives", ()))})
    result = {"scoring_version": 2, "dataset_sha256": file_digest(options.data),
              "measurement_sha256": file_digest(options.measurements),
              **cleanup_scoring.summarize(scored), "results": scored}
    options.output.parent.mkdir(parents=True, exist_ok=True)
    options.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result["overall"]))


def input_variant(value):
    """``KIND=RATE`` for ``--input-variant``."""
    kind, _, rate = value.partition("=")
    try:
        share = float(rate)
    except ValueError:
        share = -1
    if kind not in INPUT_VARIANTS or not 0 <= share <= 0.5:
        raise argparse.ArgumentTypeError(f"expected KIND=RATE, KIND one of {', '.join(INPUT_VARIANTS)} and RATE from 0 to 0.5")
    return kind, share


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    prepare_parser = commands.add_parser("prepare", help="prepare speech seeds with optional diagnostic stress variants")
    prepare_parser.add_argument("--kind", choices=("deep", "medium"), default="deep")
    prepare_parser.add_argument("--input-dir", type=Path, default=TRAINING / "generated")
    prepare_parser.add_argument("--output", type=Path, required=True)
    prepare_parser.add_argument("--stress-profiles", action="store_true", help="optional bulk punctuation stress variants; not the default training mix")
    prepare_parser.add_argument("--rules", type=Path, default=RULES)
    prepare_parser.add_argument("--composite-share", type=float, default=COMPOSITE_SHARE,
                                help="share of joinable Deep seed dictations joined into longer ones (0 for none)")
    audio_parser = commands.add_parser("audio", help="speak original dictations, not cleaned targets")
    audio_parser.add_argument("--dataset", type=Path, required=True)
    audio_parser.add_argument("--output", type=Path, required=True)
    audio_size = audio_parser.add_mutually_exclusive_group()
    audio_size.add_argument("--limit", type=int, default=60)
    audio_size.add_argument("--all", action="store_true", help="synthesize every non-placeholder source family")
    audio_parser.add_argument("--voice", default="Samantha")
    audio_parser.add_argument("--rate", type=int, default=180)
    audio_parser.add_argument("--jobs", type=int, default=1, help="clips synthesized at once")
    merge_parser = commands.add_parser("merge-asr", help="import measured transcripts with audio/model provenance")
    merge_parser.add_argument("--dataset", type=Path, required=True)
    merge_parser.add_argument("--audio-manifest", type=Path, required=True)
    merge_parser.add_argument("--transcripts", type=Path, action="append", required=True)
    merge_parser.add_argument("--include-synthetic", action="store_true",
                              help="also include the source bank; default is measured speech, placeholder rehearsal and bounded sound-alike inputs")
    merge_parser.add_argument("--output", type=Path, required=True)
    merge_parser.add_argument("--rules", type=Path, default=RULES)
    merge_parser.add_argument("--sound-alike-rate", type=float, default=0.1)
    merge_parser.add_argument("--include-synthetic-category", action="append", default=[], metavar="CATEGORY",
                              help="keep this category's synthetic rows in train and valid (repeatable)")
    merge_parser.add_argument("--include-transcript-seeds", action="store_true",
                              help="add the rules file's transcript_seeds to their splits")
    merge_parser.add_argument("--input-variant", type=input_variant, action="append", default=[], metavar="KIND=RATE",
                              help="share of measured train and valid families also given as another recognizer "
                                   f"writes them, one of {', '.join(INPUT_VARIANTS)} (repeatable)")
    quarantine_parser = commands.add_parser("quarantine", help="set aside the rows an audit blocked, with its reasons")
    quarantine_parser.add_argument("--dataset", type=Path, required=True)
    quarantine_parser.add_argument("--audit", type=Path, required=True)
    score_parser = commands.add_parser("score", help="score meaning and required punctuation before comparing adapters")
    score_parser.add_argument("--data", type=Path, required=True)
    score_parser.add_argument("--measurements", type=Path, required=True)
    score_parser.add_argument("--output", type=Path, required=True)
    options = parser.parse_args()
    if options.command == "prepare" and not 0 <= options.composite_share <= 1:
        parser.error("--composite-share must be between 0 and 1")
    if options.command == "audio" and (options.limit <= 0 or options.rate <= 0 or options.jobs <= 0):
        parser.error("--limit, --rate and --jobs must be positive")
    if options.command == "merge-asr" and not 0 <= options.sound_alike_rate <= 0.2:
        parser.error("--sound-alike-rate must be between 0 and 0.2")
    if options.command == "merge-asr" and len({kind for kind, _ in options.input_variant}) != len(options.input_variant):
        parser.error("--input-variant names each kind once")
    try:
        {"prepare": prepare, "audio": audio, "merge-asr": merge_asr, "quarantine": quarantine,
         "score": score}[options.command](options)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"error: {error}\n")


if __name__ == "__main__":
    main()
