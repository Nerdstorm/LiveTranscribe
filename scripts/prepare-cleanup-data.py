#!/usr/bin/env python3
"""Prepare synthetic cleanup inputs and optionally replace them with measured ASR.

Prepare speech seeds, reconcile measured speech-to-text pairs, and score exact text.
Private dictation history is not a training-data source.
"""

import argparse
from collections import Counter, defaultdict
import copy
import hashlib
import json
import math
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unicodedata

sys.path.insert(0, str(Path(__file__).resolve().parent))
from cleanup_data_rules import TOKEN, canonical, reconcile, units


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


def transform(text, profile):
    def unprotected(part):
        if profile == "missing-separators":
            return part.translate(str.maketrans("", "", ",:;"))
        if profile == "changed-separators":
            return part.translate(str.maketrans({",": ".", ":": ",", ";": ","}))
        if profile == "lowercase":
            return part.lower()
        if profile != "original":
            raise ValueError(f"unknown profile: {profile}")
        return part

    pieces, cursor = [], 0
    for match in PROTECTED.finditer(text):
        pieces.extend((unprotected(text[cursor:match.start()]), match.group()))
        cursor = match.end()
    pieces.append(unprotected(text[cursor:]))
    result = "".join(pieces)
    if normalize(result) != normalize(text):
        raise ValueError("augmentation changed words")
    return result


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
    manifest, table = [], []
    with tempfile.TemporaryDirectory(prefix="lt-cleanup-tts-") as scratch:
        for index, row in enumerate(selected, 1):
            spoken = " ".join(row["raw"].split())
            clip_id = digest({"family": row["family_id"], "spoken": spoken,
                              "voice": options.voice, "rate": options.rate})[:24]
            text_file = Path(scratch) / "spoken.txt"
            aiff_file = Path(scratch) / "clip.aiff"
            wav_file = options.output / f"{clip_id}.wav"
            text_file.write_text(spoken)
            subprocess.run(["say", "-v", options.voice, "-r", str(options.rate),
                            "-f", str(text_file), "-o", str(aiff_file)], check=True, capture_output=True)
            subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1",
                            str(aiff_file), str(wav_file)], check=True, capture_output=True)
            manifest.append({"id": clip_id, "example": row, "spoken": spoken,
                             "audio_sha256": file_digest(wav_file),
                             "tts": {"voice": options.voice, "rate": options.rate, "sample_rate": 16000}})
            target = row["target"].replace("\n", "\\n").replace("\t", " ")
            table.append("\t".join((clip_id, row["category"], spoken, target)))
            if index % 20 == 0:
                print(f"Synthesized {index}/{len(selected)} clips", flush=True)
    write_rows(options.output / "audio-manifest.jsonl", manifest)
    (options.output / "clips.tsv").write_text("\n".join(table) + "\n")
    print(json.dumps({"clips": len(manifest), "placeholder_families_not_spoken": skipped,
                      "output": str(options.output)}))


def merge_asr(options):
    policy, policy_path = policy_for(options)
    source_data = read_dataset(options.dataset)
    source_report = json.loads((options.dataset / "preparation-report.json").read_text())
    data = source_data if options.include_synthetic else {split: [] for split in SPLITS}
    audio_rows = read_rows(options.audio_manifest)
    clips = {row["id"]: row for row in audio_rows}
    if len(clips) != len(audio_rows):
        raise ValueError("duplicate clip ids in audio manifest")
    families = {row["family_id"]: row for rows in source_data.values() for row in rows if row["profile"] == "original"}
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
            current = families.get(original["family_id"])
            if current != original:
                raise ValueError("audio was generated from a different dataset")
            if not isinstance(transcript.get("raw"), str) or not transcript["raw"].strip():
                raise ValueError(f"empty ASR transcript for clip {clip['id']}")
            row = copy.deepcopy(original)
            target, reconciliation = reconcile(original, clip["spoken"], transcript["raw"], policy)
            row.update({"raw": transcript["raw"], "profile": "measured-asr",
                        "target": target, "reconciliation": reconciliation,
                        "id": f"{original['family_id']}-asr-{digest(transcript)[:12]}",
                        "source": f"asr:{digest(transcript['model'])[:12]}:{clip['id']}",
                        "review_required": bool(reconciliation["unresolved"]),
                        "provenance": {"kind": "tts-asr", "tts": clip["tts"],
                                       "model": transcript["model"],
                                       "model_config_sha256": transcript["model_config_sha256"],
                                       "model_weights_sha256": transcript["model_weights_sha256"],
                                       "language": transcript.get("language", "auto"),
                                       "audio_sha256": clip["audio_sha256"], "clip_id": clip["id"]}})
            if source_report.get("kind") == "deep" and original["category"] in ("facts", "unchanged", "series") and any(
                change["rule"] == "sound-alike-retain-target" for change in reconciliation["changes"]
            ):
                row.update(category="recognition", source_category=original["category"])
            if reconciliation["exclude_reason"]:
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
    save_dataset(options.output, data, {"stage": "candidate-data", "asr_models": models,
                                      "kind": source_report.get("kind"), "excluded_pairs": len(excluded),
                                      "sound_alike_rate": phonetic_rate, "rules_sha256": file_digest(policy_path),
                                      "includes_synthetic": options.include_synthetic,
                                      "source_dataset_sha256": {split: file_digest(options.dataset / f"{split}.jsonl") for split in SPLITS},
                                      "transcripts": transcripts,
                                      "audio_manifest_sha256": file_digest(options.audio_manifest)})
    write_rows(options.output / "excluded.jsonl", excluded)
    print(json.dumps({"output": str(options.output), "asr_rows": len(clips) * len(options.transcripts),
                      "excluded_pairs": len(excluded), "candidate_rows": sum(map(len, data.values())),
                      "review_required": sum(row.get("review_required", False) for rows in data.values() for row in rows)}))


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

    def text(value):
        return unicodedata.normalize("NFC", value.replace("\r\n", "\n")).strip()

    def marks(value, mark):
        tokens = list(TOKEN.finditer(value))
        return [sum(token.end() <= index for token in tokens) for index, char in enumerate(value) if char == mark]

    scored = []
    for row in rows:
        if row["raw"] != sources[row["id"]]["raw"]:
            raise ValueError("measurement inputs do not match the held-out dataset")
        target, shown = text(row["target"]), text(row["shown"])
        scored.append({"id": row["id"], "category": row["category"],
                       "exact_text": shown == target,
                       "case_sensitive_words": [m.group() for m in TOKEN.finditer(shown)] == [m.group() for m in TOKEN.finditer(target)],
                       "question_marks": marks(shown, "?") == marks(target, "?"),
                       "colons": marks(shown, ":") == marks(target, ":")})
    metrics = ("exact_text", "case_sensitive_words", "question_marks", "colons")
    def counts(rows):
        return dict(total=len(rows), **{metric: sum(row[metric] for row in rows) for metric in metrics})
    result = {"scoring_version": 1, "dataset_sha256": file_digest(options.data),
              "measurement_sha256": file_digest(options.measurements), "overall": counts(scored),
              "categories": {category: counts([row for row in scored if row["category"] == category]) for category in sorted({row["category"] for row in scored})},
              "results": scored}
    options.output.parent.mkdir(parents=True, exist_ok=True)
    options.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result["overall"]))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    prepare_parser = commands.add_parser("prepare", help="prepare speech seeds with optional diagnostic stress variants")
    prepare_parser.add_argument("--kind", choices=("deep", "medium"), default="deep")
    prepare_parser.add_argument("--input-dir", type=Path, default=TRAINING / "generated")
    prepare_parser.add_argument("--output", type=Path, required=True)
    prepare_parser.add_argument("--stress-profiles", action="store_true", help="optional bulk punctuation stress variants; not the default training mix")
    prepare_parser.add_argument("--rules", type=Path, default=RULES)
    audio_parser = commands.add_parser("audio", help="speak original dictations, not cleaned targets")
    audio_parser.add_argument("--dataset", type=Path, required=True)
    audio_parser.add_argument("--output", type=Path, required=True)
    audio_size = audio_parser.add_mutually_exclusive_group()
    audio_size.add_argument("--limit", type=int, default=60)
    audio_size.add_argument("--all", action="store_true", help="synthesize every non-placeholder source family")
    audio_parser.add_argument("--voice", default="Samantha")
    audio_parser.add_argument("--rate", type=int, default=180)
    merge_parser = commands.add_parser("merge-asr", help="import measured transcripts with audio/model provenance")
    merge_parser.add_argument("--dataset", type=Path, required=True)
    merge_parser.add_argument("--audio-manifest", type=Path, required=True)
    merge_parser.add_argument("--transcripts", type=Path, action="append", required=True)
    merge_parser.add_argument("--include-synthetic", action="store_true",
                              help="also include the source bank; default is measured speech, placeholder rehearsal and bounded sound-alike inputs")
    merge_parser.add_argument("--output", type=Path, required=True)
    merge_parser.add_argument("--rules", type=Path, default=RULES)
    merge_parser.add_argument("--sound-alike-rate", type=float, default=0.1)
    score_parser = commands.add_parser("score", help="score casing, punctuation, question marks and colons before comparing adapters")
    score_parser.add_argument("--data", type=Path, required=True)
    score_parser.add_argument("--measurements", type=Path, required=True)
    score_parser.add_argument("--output", type=Path, required=True)
    options = parser.parse_args()
    if options.command == "audio" and (options.limit <= 0 or options.rate <= 0):
        parser.error("--limit and --rate must be positive")
    if options.command == "merge-asr" and not 0 <= options.sound_alike_rate <= 0.2:
        parser.error("--sound-alike-rate must be between 0 and 0.2")
    try:
        {"prepare": prepare, "audio": audio, "merge-asr": merge_asr, "score": score}[options.command](options)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"error: {error}\n")


if __name__ == "__main__":
    main()
