#!/usr/bin/env python3
"""Regression checks for input integrity, holdouts and measured-ASR provenance."""

import argparse
from collections import Counter
import copy
import importlib.util
import json
from pathlib import Path
import re
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("prepare_cleanup_data", Path(__file__).resolve().parents[1] / "prepare-cleanup-data.py")
prep = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prep)
seeds_spec = importlib.util.spec_from_file_location("transcript_seeds", Path(__file__).resolve().parents[1] / "transcript-seeds.py")
seeds = importlib.util.module_from_spec(seeds_spec)
seeds_spec.loader.exec_module(seeds)


def example(raw, identity, split="train", **extra):
    row = {"raw": raw, "target": raw, "category": "unchanged", "context": [],
           "multiline": False, "letterBody": False, "source": "synthetic-test",
           "id": identity, "family_id": identity, "split": split, "profile": "original"}
    row.update(extra)
    return row


class PreparationTests(unittest.TestCase):
    def test_values_addresses_contractions_and_placeholders_survive(self):
        text = "John's API v1.2.3 costs 1,000.50 or 22,50 at 12:30 on 2026-10-01; email a.b@example.com, see https://example.com/a?b=2 and U.S. ⟦S1⟧ T2."
        for profile in prep.PROFILES:
            transformed = prep.transform(text, profile)
            self.assertEqual(prep.normalize(text), prep.normalize(transformed))
            for token in ("1,000.50", "22,50", "12:30", "2026-10-01", "a.b@example.com", "https://example.com/a?b=2", "U.S.", "⟦S1⟧", "T2"):
                self.assertIn(token, transformed)
            self.assertIn("'", transformed)

    def test_unpunctuated_input_is_lower_case_with_values_and_placeholders_kept(self):
        text = "Hi, Sam. The link is ⟦S1⟧. It starts at 9:30 p.m. — bring the U.S. forms, okay? It's $12,000… six—no wait, fifty."
        self.assertEqual(prep.transform(text, "unpunctuated"),
                         "hi sam the link is ⟦S1⟧ it starts at 9:30 p.m. bring the U.S. forms okay it's $12,000 six no wait fifty")

    def test_question_signal_stays_in_all_profiles(self):
        for profile in prep.PROFILES:
            self.assertEqual(prep.transform("You're coming tomorrow? No, Thursday.", profile).count("?"), 1)

    def test_two_item_list_gets_missing_and_wrong_colon_inputs(self):
        source = "Two things we need: the charger and the passport."
        self.assertNotIn(":", prep.transform(source, "missing-separators"))
        self.assertIn("need,", prep.transform(source, "changed-separators"))
        self.assertEqual(prep.normalize(source), prep.normalize(prep.transform(source, "missing-separators")))

    def test_odd_stops_and_capitals_keep_words_and_values_and_repeat_by_seed(self):
        text = "Thanks, Priya. The Macs need a restart before the demo at 9:30 on Friday, sorry, Thursday, with the U.S. forms ⟦S1⟧."
        for kind in ("odd-stops", "odd-case"):
            results = {prep.transform(text, kind, seed=str(seed)) for seed in range(12)}
            self.assertGreater(len(results), 3, kind)
            self.assertEqual(prep.transform(text, kind, seed="a"), prep.transform(text, kind, seed="a"))
            for result in results:
                self.assertNotEqual(result, text)
                self.assertEqual(prep.normalize(result), prep.normalize(text))
                for token in ("9:30", "U.S.", "⟦S1⟧"):
                    self.assertIn(token, result)

    def test_an_odd_stop_falls_where_a_speaker_could_pause(self):
        text = "I'll send the report to Sam tomorrow, and then we can talk about the budget for next year."
        for seed in range(30):
            result = prep.transform(text, "odd-stops", seed=str(seed))
            sentences = [sentence.split() for sentence in result.split(". ")]
            self.assertTrue(all(len(sentence) > 1 for sentence in sentences), result)
            for sentence in sentences[:-1]:
                self.assertNotIn(sentence[-1].lower(), prep.NEVER_LAST, result)
            for sentence in sentences[1:]:
                self.assertTrue(sentence[0][0].isupper(), result)

    def test_case_change_preserves_protected_token_casing(self):
        self.assertEqual(prep.transform("Hello S1 ⟦T2⟧ API?", "lowercase"), "hello S1 ⟦T2⟧ api?")

    def test_cross_split_input_leak_is_detected_despite_case_and_punctuation(self):
        data = {"train": [example("The unusual purple zebra.", "a")],
                "valid": [example("the unusual purple zebra", "b", "valid")], "test": []}
        with self.assertRaisesRegex(ValueError, "normalized input"):
            prep.check_splits(data)

    def test_all_model_variants_of_a_family_stay_in_one_split(self):
        data = {"train": [example("one phrase", "a", family_id="family")],
                "valid": [example("an ASR mishearing", "b", "valid", family_id="family")], "test": []}
        with self.assertRaisesRegex(ValueError, "source family"):
            prep.check_splits(data)

    def test_history_schema_is_not_a_training_input(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "history.jsonl"
            prep.write_rows(path, [{"rawText": "private", "cleanedText": "Private."}])
            with self.assertRaisesRegex(ValueError, "evaluation-only"):
                prep.read_rows(path)

    def test_preparation_is_reproducible_and_targets_and_context_stay_exact(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            source = root / "source"
            for split in prep.SPLITS:
                prep.write_rows(source / f"deep-{split}.jsonl", [example(
                    f"A {split} zebra, sorry, a striped horse?", split, split,
                    target=f"A {split} striped horse?", context=["Earlier sentence."], letterBody=True,
                )])
                path = source / f"deep-{split}.jsonl"
                path.write_text("\n" + path.read_text())
            for output in (root / "first", root / "second"):
                prep.prepare(argparse.Namespace(kind="deep", input_dir=source, output=output))
            for split in prep.SPLITS:
                self.assertEqual((root / "first" / f"{split}.jsonl").read_bytes(), (root / "second" / f"{split}.jsonl").read_bytes())
                for row in prep.read_rows(root / "first" / f"{split}.jsonl"):
                    self.assertEqual(row["target"], f"A {split} striped horse?")
                    self.assertEqual(row["context"], ["Earlier sentence."])
                    self.assertTrue(row["letterBody"])
                    self.assertEqual(row["provenance"]["line"], 2)
                self.assertEqual(len(prep.read_rows(root / "first" / f"{split}.jsonl")), 1)

    def test_stress_profiles_are_opt_in(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            for split in prep.SPLITS:
                prep.write_rows(root / f"deep-{split}.jsonl", [example(f"A {split} zebra, not a horse?", split, split)])
            prep.prepare(argparse.Namespace(kind="deep", input_dir=root, output=root / "stress", stress_profiles=True))
            self.assertEqual(len(prep.read_rows(root / "stress/train.jsonl")), 4)
            self.assertEqual(json.loads((root / "stress/preparation-report.json").read_text())["stage"], "stress-data")

    def test_curated_training_keeps_the_shipped_double_weight(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            source, training = root / "source", root / "training"
            for split in prep.SPLITS:
                prep.write_rows(source / f"{split}.jsonl", [example(f"A unique {split} zebra.", split, split, category="cleanup")])
            prep.write_rows(training / "curated/train/work.jsonl", [{"raw": "A carefully curated sentence.", "target": "A carefully curated sentence.", "category": "cleanup"}])
            with patch.object(prep, "TRAINING", training):
                prep.prepare(argparse.Namespace(kind="medium", input_dir=source, output=root / "out"))
            rows = prep.read_rows(root / "out/train.jsonl")
            self.assertEqual(sorted(row["training_weight"] for row in rows), [1, 2])
            self.assertEqual(json.loads((root / "out/preparation-report.json").read_text())["splits"]["train"]["training_weighted_examples"], 3)

    def test_held_out_eval_is_excluded_even_after_punctuation_change(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            source = root / "source"
            training = root / "training"
            for split in prep.SPLITS:
                prep.write_rows(source / f"deep-{split}.jsonl", [example(f"Unique {split} sentence.", split, split)])
            prep.write_rows(training / "eval/held-out.jsonl", [{"raw": "unique train sentence"}])
            with patch.object(prep, "TRAINING", training):
                with self.assertRaisesRegex(ValueError, "held-out"):
                    prep.prepare(argparse.Namespace(kind="deep", input_dir=source, output=root / "out"))
            self.assertFalse((root / "out").exists())

    def test_tts_speaks_correction_instead_of_clean_target_and_skips_llm_tokens(self):
        source = example("Tuesday, sorry, Wednesday.", "a", target="Wednesday.")
        token = example("The link is ⟦S1⟧.", "b")
        selected, skipped = prep.select_audio({"train": [source, token], "valid": [], "test": []}, 5)
        self.assertEqual(selected[0]["raw"], "Tuesday, sorry, Wednesday.")
        self.assertEqual(skipped, 1)

    def test_small_audio_pilot_includes_every_split(self):
        data = {split: [example(f"A {split} zebra", split, split, category="control"),
                        example(f"A {split} horse", split + "-b", split, category="facts")]
                for split in prep.SPLITS}
        selected, _ = prep.select_audio(data, 3)
        self.assertEqual({row["split"] for row in selected}, set(prep.SPLITS))


class CompositeTests(unittest.TestCase):
    def prepare(self, rows_by_split, **options):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            for split, rows in rows_by_split.items():
                prep.write_rows(root / f"deep-{split}.jsonl", rows)
            prep.prepare(argparse.Namespace(kind="deep", input_dir=root, output=root / "out", **options))
            return ({split: prep.read_rows(root / f"out/{split}.jsonl") for split in prep.SPLITS},
                    json.loads((root / "out/preparation-report.json").read_text()))

    def seeds(self, label, count, **extra):
        animals = "zebra horse camel llama otter badger heron moose bison lemur tapir koala gecko panda raven".split()
        rows = []
        for number, animal in enumerate(animals[:count]):
            row = {"raw": f"the {label} {animal} {number} ran home", "target": f"The {label} {animal} {number} ran home.",
                   "category": "series" if number % 2 else "facts", "context": [], "multiline": False,
                   "letterBody": False, "source": "generated"}
            row.update(extra)
            rows.append(row)
        return rows

    def test_dictations_are_joined_into_longer_ones_whose_parts_leave_train_but_not_test(self):
        data, report = self.prepare({split: self.seeds(split, 10) for split in prep.SPLITS})
        for split in prep.SPLITS:
            composites = [row for row in data[split] if row["category"] == "composite"]
            singles = [row for row in data[split] if row["category"] != "composite"]
            parts = [part["id"] for row in composites for part in row["provenance"]["parts"]]
            self.assertTrue(composites, split)
            self.assertEqual(len(parts), len(set(parts)))
            self.assertEqual(report["composites"][split], {"composites": len(composites), "parts": len(parts)})
            self.assertEqual(len(singles), 10 if split == "test" else 10 - len(parts), split)
            self.assertFalse(set(parts) & {row["id"] for row in singles} if split != "test" else set())
            for row in composites:
                count = len(row["provenance"]["parts"])
                self.assertTrue(2 <= count <= 4)
                self.assertEqual(row["raw"].count("home. the"), count - 1, row["raw"])
                self.assertEqual(row["target"].count("home. The"), count - 1, row["target"])
                self.assertEqual(len(row["source_categories"]), count)
                self.assertEqual(" ".join(part["target"] for part in row["provenance"]["parts"]), row["target"])
        again, _ = self.prepare({split: self.seeds(split, 10) for split in prep.SPLITS})
        self.assertEqual(again, data)

    def test_only_paragraphs_in_one_kind_of_field_are_joined_within_the_word_limit(self):
        long_raw = " ".join(["word"] * 45)
        laid_out = [dict(row, target=row["target"].replace(" ran", "\nran")) for row in self.seeds("laid", 4)]
        tokens = [dict(row, raw=row["raw"] + " ⟦S1⟧", target=row["target"][:-1] + " ⟦S1⟧.") for row in self.seeds("token", 4)]
        context = self.seeds("context", 4, context=["Before."])
        recognition = self.seeds("knew", 4, category="recognition")
        long = [dict(row, raw=f"{long_raw} {row['raw']}", target=f"{long_raw.capitalize()} {row['target'].lower()}")
                for row in self.seeds("long", 4)]
        multiline = self.seeds("multi", 6, multiline=True)
        train = self.seeds("plain", 6) + laid_out + tokens + context + recognition + long + multiline
        data, _ = self.prepare({"train": train, "valid": self.seeds("valid", 2), "test": self.seeds("test", 2)})
        composites = [row for row in data["train"] if row["category"] == "composite"]
        self.assertEqual({row["multiline"] for row in composites}, {False, True})
        for row in composites:
            self.assertLessEqual(len(row["raw"].split()), prep.COMPOSITE_MAX_WORDS)
            self.assertNotIn("\n", row["target"])
            for word in ("laid", "token", "context", "knew"):
                self.assertNotIn(f" {word} ", row["raw"])
            self.assertEqual(row["multiline"], "multi" in row["raw"])
        singles = [row["raw"] for row in data["train"] if row["category"] != "composite"]
        for word in ("laid", "token", "context", "knew"):
            self.assertEqual(sum(f" {word} " in raw for raw in singles), 4, word)

    def test_composites_are_opt_out(self):
        data, report = self.prepare({split: self.seeds(split, 10) for split in prep.SPLITS}, composite_share=0)
        self.assertFalse(any(row["category"] == "composite" for split in prep.SPLITS for row in data[split]))
        self.assertEqual(report["composites"], {})


class MeasuredASRTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.data = {split: [example(f"A {split} zebra.", split, split)] for split in prep.SPLITS}
        prep.save_dataset(self.root / "dataset", self.data, {"kind": "deep"})
        self.original = self.data["train"][0]
        self.clip = {"id": "clip", "example": self.original, "spoken": self.original["raw"],
                     "audio_sha256": "audio", "tts": {"voice": "Samantha", "rate": 180}}
        prep.write_rows(self.root / "audio.jsonl", [self.clip])
        self.transcript = {"id": "clip", "raw": "a train zebra?", "model": "/pinned/model",
                           "model_config_sha256": "model-config", "model_weights_sha256": "model-weights", "audio_sha256": "audio"}

    def merge(self, transcripts, include_synthetic=False):
        prep.write_rows(self.root / "asr.jsonl", transcripts)
        prep.merge_asr(argparse.Namespace(dataset=self.root / "dataset", audio_manifest=self.root / "audio.jsonl",
                                         transcripts=[self.root / "asr.jsonl"], output=self.root / "merged",
                                         include_synthetic=include_synthetic))

    def test_a_sound_alike_fixed_in_a_list_kept_on_one_line_is_a_word_fix(self):
        self.original.update(raw="Two things: merge the patch and call Sam.", category="list-two",
                             target="Two things: merge the patch and call Sam.")
        self.data["train"] = [self.original]
        prep.save_dataset(self.root / "dataset", self.data, {"kind": "deep"})
        self.clip.update(example=self.original, spoken=self.original["raw"])
        prep.write_rows(self.root / "audio.jsonl", [self.clip])
        self.transcript["raw"] = "Two things. Madge the patch and call Sam."
        self.merge([self.transcript])
        measured = prep.read_rows(self.root / "merged/train.jsonl")[-1]
        self.assertEqual(measured["category"], "recognition")
        self.assertEqual(measured["source_category"], "list-two")

    def test_actual_asr_punctuation_is_preserved_and_target_is_unchanged(self):
        self.merge([self.transcript])
        measured = prep.read_rows(self.root / "merged/train.jsonl")[-1]
        self.assertEqual(measured["raw"], "a train zebra?")
        self.assertEqual(measured["target"], self.original["target"])
        self.assertFalse(measured["review_required"])
        self.assertEqual(measured["family_id"], self.original["family_id"])
        self.assertEqual(measured["provenance"]["model_config_sha256"], "model-config")
        self.assertEqual(measured["provenance"]["language"], "auto")

    def test_measured_inputs_are_separate_from_stress_variants_unless_requested(self):
        self.merge([self.transcript])
        self.assertEqual(len(prep.read_rows(self.root / "merged/train.jsonl")), 1)
        self.assertEqual(prep.read_rows(self.root / "merged/valid.jsonl"), [])
        self.merge([self.transcript], include_synthetic=True)
        self.assertEqual(len(prep.read_rows(self.root / "merged/train.jsonl")), 2)
        self.assertEqual(len(prep.read_rows(self.root / "merged/valid.jsonl")), 1)

    def test_a_named_category_keeps_its_synthetic_rows_outside_the_held_out_test(self):
        for split in prep.SPLITS:
            self.data[split].append(example(f"The knew {split} laptop arrived.", f"{split}-word", split, category="recognition"))
        prep.save_dataset(self.root / "dataset", self.data, {"kind": "deep"})
        self.clip["example"] = self.data["train"][0]
        prep.write_rows(self.root / "audio.jsonl", [self.clip])
        prep.write_rows(self.root / "asr.jsonl", [self.transcript])
        prep.merge_asr(argparse.Namespace(dataset=self.root / "dataset", audio_manifest=self.root / "audio.jsonl",
                                         transcripts=[self.root / "asr.jsonl"], output=self.root / "merged",
                                         include_synthetic=False, include_synthetic_category=["recognition"]))
        kept = {split: [row["id"] for row in prep.read_rows(self.root / f"merged/{split}.jsonl") if row["category"] == "recognition"]
                for split in prep.SPLITS}
        self.assertEqual(kept, {"train": ["train-word"], "valid": ["valid-word"], "test": []})
        report = json.loads((self.root / "merged/preparation-report.json").read_text())
        self.assertEqual(report["synthetic_categories"], ["recognition"])

    def test_transcript_seeds_are_added_to_their_splits_only_when_asked(self):
        self.merge([self.transcript])
        self.assertFalse(any(row["profile"] == "transcript-seed" for split in prep.SPLITS
                             for row in prep.read_rows(self.root / f"merged/{split}.jsonl")))
        prep.write_rows(self.root / "asr.jsonl", [self.transcript])
        prep.merge_asr(argparse.Namespace(dataset=self.root / "dataset", audio_manifest=self.root / "audio.jsonl",
                                         transcripts=[self.root / "asr.jsonl"], output=self.root / "merged",
                                         include_synthetic=False, include_transcript_seeds=True))
        policy = json.loads(prep.RULES.read_text())
        for split in prep.SPLITS:
            seeds = [row for row in prep.read_rows(self.root / f"merged/{split}.jsonl") if row["profile"] == "transcript-seed"]
            self.assertEqual(len(seeds), len(policy["transcript_seeds"][split]), split)
            self.assertTrue(all(row["provenance"]["kind"] == "synthetic-transcript" for row in seeds))
        self.assertTrue(json.loads((self.root / "merged/preparation-report.json").read_text())["transcript_seeds"])

    def test_input_variants_are_drawn_by_family_in_train_and_valid_only(self):
        sizes = {"train": 4, "valid": 2, "test": 2}
        self.data = {split: [example(f"The {split} zebra {i} ran home after lunch.", f"{split}-{i}", split) for i in range(size)]
                     for split, size in sizes.items()}
        prep.save_dataset(self.root / "dataset", self.data, {"kind": "deep"})
        clips = [dict(self.clip, id=row["id"], example=row, spoken=row["raw"]) for rows in self.data.values() for row in rows]
        prep.write_rows(self.root / "audio.jsonl", clips)
        prep.write_rows(self.root / "asr.jsonl", [dict(self.transcript, id=clip["id"], raw=clip["spoken"]) for clip in clips])
        prep.merge_asr(argparse.Namespace(dataset=self.root / "dataset", audio_manifest=self.root / "audio.jsonl",
                                         transcripts=[self.root / "asr.jsonl"], output=self.root / "merged",
                                         include_synthetic=False, input_variant=[("unpunctuated", 0.5), ("odd-stops", 0.5)]))
        rows = {split: prep.read_rows(self.root / f"merged/{split}.jsonl") for split in prep.SPLITS}
        variants = [row for split in prep.SPLITS for row in rows[split] if row["profile"] in prep.INPUT_VARIANTS]
        self.assertEqual(Counter(row["profile"] for row in variants), {"unpunctuated": 3, "odd-stops": 3})
        self.assertFalse(any(row["profile"] != "measured-asr" for row in rows["test"]))
        for variant in variants:
            parent = next(row for row in rows[variant["split"]] if row["id"] == variant["provenance"]["parent_id"])
            if variant["profile"] == "unpunctuated":
                self.assertEqual(variant["raw"], parent["raw"].lower().replace(".", ""))
            else:
                self.assertEqual(prep.normalize(variant["raw"]), prep.normalize(parent["raw"]))
                self.assertGreater(variant["raw"].count("."), 1)
            self.assertEqual((variant["target"], variant["family_id"]), (parent["target"], parent["family_id"]))
            self.assertEqual(variant["provenance"]["kind"], "derived-" + variant["profile"])
        report = json.loads((self.root / "merged/preparation-report.json").read_text())
        self.assertEqual(report["input_variants"], {"unpunctuated": 0.5, "odd-stops": 0.5})
        self.assertEqual(report["input_variant_rows"], {"odd-stops": 3, "unpunctuated": 3})

    def test_input_variants_are_named_with_a_rate(self):
        self.assertEqual(prep.input_variant("odd-stops=0.2"), ("odd-stops", 0.2))
        for value in ("odd-stops", "shouting=0.1", "odd-case=0.6", "lowercase=x"):
            with self.assertRaises(argparse.ArgumentTypeError):
                prep.input_variant(value)

    def test_an_answer_keeps_the_optional_commas_of_its_own_input(self):
        self.original.update(raw="Yes, I bought apples, pears and plums, and Sam paid.",
                             target="Yes, I bought apples, pears and plums, and Sam paid.")
        prep.save_dataset(self.root / "dataset", self.data, {"kind": "deep"})
        self.clip.update(example=self.original, spoken=self.original["raw"])
        prep.write_rows(self.root / "audio.jsonl", [self.clip])
        self.transcript["raw"] = "Yes I bought apples pears and plums and Sam paid."
        prep.write_rows(self.root / "asr.jsonl", [self.transcript])
        prep.merge_asr(argparse.Namespace(dataset=self.root / "dataset", audio_manifest=self.root / "audio.jsonl",
                                         transcripts=[self.root / "asr.jsonl"], output=self.root / "merged",
                                         include_synthetic=False))
        measured = prep.read_rows(self.root / "merged/train.jsonl")[-1]
        # The commas between list items are English's; the others were the writer's.
        self.assertEqual(measured["target"], "Yes I bought apples, pears and plums and Sam paid.")
        self.assertEqual(measured["target_before_optional_commas"], self.original["target"])
        report = json.loads((self.root / "merged/preparation-report.json").read_text())
        self.assertEqual(report["optional_commas_carried"], {"train": 1})

    def test_a_composite_that_needs_review_gives_back_its_parts_the_recognizer_wrote_as_said(self):
        parts = [example(raw, f"part-{index}", category=category, target=target) for index, (raw, target, category) in enumerate([
            ("the zebra ran home", "The zebra ran home.", "facts"),
            ("Ask Sam to call the vet.", "Ask Sam to call the vet.", "unchanged"),
            ("The heron flew off, sorry, the swan.", "The swan flew off.", "same-sentence"),
        ])]
        joined = prep.composite(parts, "train")
        self.data["train"] = [joined]
        prep.save_dataset(self.root / "dataset", self.data, {"kind": "deep"})
        self.clip.update(example=joined, spoken=joined["raw"])
        prep.write_rows(self.root / "audio.jsonl", [self.clip])
        # "vet" heard as "bet": that part needs review; the recognizer ran nothing across an edge.
        self.transcript["raw"] = "The zebra ran home. Ask Sam to call the bet. The heron flew off. Sorry, the swan."
        self.merge([self.transcript])
        rows = prep.read_rows(self.root / "merged/train.jsonl")
        whole = next(row for row in rows if row["category"] == "composite")
        self.assertTrue(whole["review_required"])
        given = {row["family_id"]: row for row in rows if row["category"] != "composite"}
        self.assertEqual(set(given), {"part-0", "part-1", "part-2"})
        self.assertEqual((given["part-0"]["raw"], given["part-0"]["target"], given["part-0"]["review_required"]),
                         ("The zebra ran home.", "The zebra ran home.", False))
        self.assertTrue(given["part-1"]["review_required"])
        self.assertEqual((given["part-2"]["raw"], given["part-2"]["target"], given["part-2"]["category"]),
                         ("The heron flew off. Sorry, the swan.", "The swan flew off.", "same-sentence"))
        for row in given.values():
            self.assertEqual(row["provenance"]["composite_id"], joined["id"])
            self.assertEqual(row["provenance"]["clip_id"], "clip")

    def test_a_quote_a_part_opens_with_goes_with_it(self):
        joined = {"raw": "the zebra ran home. ask sam to call", "provenance": {"parts": [
            {"raw": "the zebra ran home"}, {"raw": "ask sam to call"}]}}
        policy = json.loads(prep.RULES.read_text())
        parts = prep.composite_parts(joined, 'The zebra ran home. "Ask Sam to call."', policy)
        self.assertEqual([heard for _, _, heard in parts], ["The zebra ran home.", '"Ask Sam to call."'])

    def test_a_part_whose_edge_the_recognizer_changed_is_not_given_back(self):
        parts = [example("the zebra ran home", "part-0", target="The zebra ran home."),
                 example("the heron flew off", "part-1", target="The heron flew off.")]
        joined = prep.composite(parts, "train")
        self.data["train"] = [joined]
        prep.save_dataset(self.root / "dataset", self.data, {"kind": "deep"})
        self.clip.update(example=joined, spoken=joined["raw"])
        prep.write_rows(self.root / "audio.jsonl", [self.clip])
        self.transcript["raw"] = "The zebra ran hum. They're on flew off."
        self.merge([self.transcript])
        rows = prep.read_rows(self.root / "merged/train.jsonl")
        self.assertEqual([row["category"] for row in rows], ["composite"])

    def test_word_changes_are_flagged_for_review(self):
        self.transcript["raw"] = "A train horse."
        self.merge([self.transcript])
        self.assertTrue(prep.read_rows(self.root / "merged/train.jsonl")[-1]["review_required"])

    def test_audio_from_a_different_run_is_rejected(self):
        self.transcript["audio_sha256"] = "different-audio"
        with self.assertRaisesRegex(ValueError, "stale or different audio"):
            self.merge([self.transcript])

    def test_missing_and_duplicate_clip_results_are_rejected(self):
        with self.assertRaisesRegex(ValueError, "exactly"):
            self.merge([])
        with self.assertRaisesRegex(ValueError, "duplicate"):
            self.merge([self.transcript, self.transcript])

    def test_audio_of_a_family_with_a_cased_and_a_lowercase_row_is_accepted(self):
        lowercase = example("a train zebra", "train-lowercase", "train", family_id="train")
        self.data["train"].append(lowercase)
        prep.save_dataset(self.root / "dataset", self.data, {"kind": "deep"})
        other = dict(self.clip, id="clip-lowercase", example=lowercase, spoken=lowercase["raw"])
        prep.write_rows(self.root / "audio.jsonl", [self.clip, other])
        self.merge([self.transcript, dict(self.transcript, id="clip-lowercase")])
        measured = [row for row in prep.read_rows(self.root / "merged/train.jsonl") if row["profile"] == "measured-asr"]
        self.assertEqual(len(measured), 2)

    def test_audio_from_an_older_dataset_is_rejected(self):
        self.clip["example"] = copy.deepcopy(self.original)
        self.clip["example"]["target"] = "A different target."
        prep.write_rows(self.root / "audio.jsonl", [self.clip])
        with self.assertRaisesRegex(ValueError, "different dataset"):
            self.merge([self.transcript])

    def test_placeholder_rehearsal_returns_at_the_source_family_rate(self):
        token = example("Please send ⟦S1⟧ to the team.", "token", category="placeholder")
        self.data["train"].append(token)
        prep.save_dataset(self.root / "dataset", self.data, {"kind": "deep"})
        self.merge([self.transcript])
        rows = prep.read_rows(self.root / "merged/train.jsonl")
        self.assertEqual(sum(row["profile"] == "placeholder-rehearsal" for row in rows), 1)
        self.assertTrue(any(row["raw"] == token["raw"] and row["target"] == token["target"] for row in rows))

    def test_sound_alike_inputs_are_whole_sentences_and_capped_by_family(self):
        adjectives = "amber blue crimson dusty emerald frosted green hazel indigo jade".split()
        originals = [example(f"Please merge the {adjective} patch.", f"sound-{i}", category="facts") for i, adjective in enumerate(adjectives)]
        originals += [example(f"Max sent the {adjective} draft.", f"name-{i}", category="facts") for i, adjective in enumerate(adjectives)]
        self.data["train"] = originals
        prep.save_dataset(self.root / "dataset", self.data, {"kind": "deep"})
        clips = [dict(self.clip, id=f"clip-{i}", example=row, spoken=row["raw"]) for i, row in enumerate(originals)]
        transcripts = [dict(self.transcript, id=clip["id"], raw=clip["spoken"]) for clip in clips]
        prep.write_rows(self.root / "audio.jsonl", clips)
        self.merge(transcripts)
        rows = prep.read_rows(self.root / "merged/train.jsonl")
        phonetic = [row for row in rows if row["profile"] == "sound-alike"]
        self.assertEqual(len(phonetic), 1)
        self.assertTrue(phonetic[0]["raw"].startswith("Please madge the "))
        self.assertTrue(phonetic[0]["target"].startswith("Please merge the "))
        self.assertEqual(phonetic[0]["split"], "train")
        self.assertEqual(phonetic[0]["provenance"]["kind"], "synthetic-sound-alike")


class ReconciliationTests(unittest.TestCase):
    def setUp(self):
        self.policy = json.loads(prep.RULES.read_text())

    def reconcile(self, spoken, heard, target=None, category="unchanged"):
        return prep.reconcile({"raw": spoken, "target": target or spoken, "category": category}, spoken, heard, self.policy)

    def test_name_spelling_adapts_target_without_guessing_the_name(self):
        target, trail = self.reconcile("Siobhan sent the draft.", "Shavon sent the draft.")
        self.assertEqual(target, "Shavon sent the draft.")
        self.assertEqual(trail["status"], "automatic")
        target, trail = self.reconcile("Foxhill Rovers won the final.", "Fox Hill Rovers won the final.")
        self.assertEqual(target, "Fox Hill Rovers won the final.")
        self.assertFalse(trail["unresolved"])

    def test_name_to_pronoun_or_different_known_name_stays_unresolved(self):
        for source, heard in (("Ewan", "You"), ("John", "Sam"), ("Mateo", "Maya"), ("Max", "Macs")):
            _, trail = self.reconcile(f"{source} sent the draft.", f"{heard} sent the draft.")
            self.assertEqual(trail["status"], "review")

    def test_name_spelling_changes_only_the_matching_retained_occurrence(self):
        target, trail = self.reconcile("Siobhan spoke to Siobhan.", "Shavon spoke to Siobhan.")
        self.assertEqual(target, "Shavon spoke to Siobhan.")
        self.assertFalse(trail["unresolved"])
        target, trail = self.reconcile("Siobhan, sorry, Siobhan sent the draft.",
                                       "Shavon, sorry, Siobhan sent the draft.",
                                       target="Siobhan sent the draft.", category="same-sentence")
        self.assertEqual(target, "Siobhan sent the draft.")
        self.assertFalse(trail["unresolved"])

    def test_digit_number_and_time_forms_preserve_values(self):
        target, trail = self.reconcile("We need twenty laptops by two pm.", "We need 20 laptops by 2 p.m.")
        self.assertEqual(target, "We need 20 laptops by 2 p.m.")
        self.assertFalse(trail["unresolved"])
        target, trail = self.reconcile("The meeting starts at two pm.", "The meeting starts at 2:00 p.m.")
        self.assertEqual(target, "The meeting starts at 2:00 p.m.")
        self.assertFalse(trail["unresolved"])
        for source, heard in (("twenty two", "22"), ("twelfth", "12th"), ("seven thirty", "7:30"), ("1000th", "1,000th")):
            _, trail = self.reconcile(f"It is {source}.", f"It is {heard}.")
            self.assertFalse(trail["unresolved"], (source, heard, trail))

    def test_number_change_is_never_reconciled_as_formatting(self):
        _, trail = self.reconcile("We need twenty laptops.", "We need 21 laptops.")
        self.assertEqual(trail["status"], "review")
        for source, heard in (("001", "1"), ("-001", "-1"), ("v1.20", "v1.2"), ("v1.20", "v12.0"), ("123456789012345678901234567890", "123456789012345678901234567891")):
            _, trail = self.reconcile(f"The identifier is {source}.", f"The identifier is {heard}.")
            self.assertEqual(trail["status"], "review", (source, heard))

    def test_changed_address_is_not_hidden_by_punctuation_normalization(self):
        _, trail = self.reconcile("Visit https://example.com/ab.c today.", "Visit https://example.com/a.bc today.")
        self.assertEqual(trail["status"], "review")

    def test_spelling_and_contraction_forms_keep_the_recognizers_choice(self):
        target, trail = self.reconcile("There's a grey sign at the centre.", "There is a gray sign at the center.")
        self.assertEqual(target, "There is a gray sign at the center.")
        self.assertFalse(trail["unresolved"])

    def test_sound_alike_common_word_keeps_its_clean_target_in_context(self):
        target, trail = self.reconcile("Please merge the patch after testing.", "Please Madge the patch after testing.")
        self.assertEqual(target, "Please merge the patch after testing.")
        self.assertFalse(trail["unresolved"])
        self.assertTrue(any(change["rule"] == "sound-alike-retain-target" for change in trail["changes"]))

    def test_recognizer_repair_of_a_planted_error_is_excluded(self):
        target, trail = self.reconcile("Your right about the minutes.", "You're right about the minutes.", target="You're right about the minutes.", category="recognition")
        self.assertEqual(trail["exclude_reason"], "planted-error-already-corrected")
        self.assertEqual(target, "You're right about the minutes.")

    def test_regional_spelling_spacing_articles_and_titles_keep_the_recognizers_choice(self):
        for spoken, heard in (("The neighbours cancelled the meeting.", "The neighbors canceled the meeting."),
                              ("The frontend needs work.", "The front end needs work."),
                              ("Restart the wifi first.", "Restart the Wi-Fi first."),
                              ("Please send the quote.", "Please send a quote."),
                              ("Dear Mr Brown, thanks.", "Dear Mister Brown, thanks."),
                              ("Hana sent the draft.", "Hannah sent the draft.")):
            target, trail = self.reconcile(spoken, heard)
            self.assertEqual(target, heard, trail)
            self.assertFalse(trail["unresolved"], trail)
        target, trail = self.reconcile("Sign in to your account.", "Sign into your account.", target="1. Sign in to your account.", category="list-many")
        self.assertEqual(target, "1. Sign into your account.")

    def test_amounts_and_times_written_differently_keep_their_value(self):
        target, trail = self.reconcile("The invoice for three hundred dollars is due.", "The invoice for $300 is due.")
        self.assertEqual(target, "The invoice for $300 is due.")
        self.assertFalse(trail["unresolved"])
        target, trail = self.reconcile("The shop closes at four pm today.", "The shop closes at 4:00 today.")
        self.assertEqual(target, "The shop closes at 4:00 today.")
        self.assertFalse(trail["unresolved"])
        target, trail = self.reconcile("The budget is capped at twelve thousand.", "The budget is capped at $12,000.")
        self.assertEqual(target, "The budget is capped at $12,000.")
        self.assertFalse(trail["unresolved"])
        _, trail = self.reconcile("The invoice for three hundred dollars is due.", "The invoice for $30 is due.")
        self.assertEqual(trail["status"], "review")

    def test_a_word_a_correction_moves_keeps_its_recognized_form(self):
        target, trail = self.reconcile("Yuki will cover my shift. Sorry, I mean Gita.", "Yuki will cover my shift. Sorry, I mean Jida.",
                                       target="Gita will cover my shift.", category="cross-sentence")
        self.assertEqual(target, "Jida will cover my shift.")
        target, _ = self.reconcile("The shop closes at three pm today. Wait, no, four pm.", "The shop closes at 3 p.m. today. Wait, no, 4 p.m.",
                                   target="The shop closes at four pm today.", category="cross-sentence")
        self.assertEqual(target, "The shop closes at 4 p.m. today.")

    def test_an_apostrophe_heard_wrong_keeps_the_clean_target(self):
        target, trail = self.reconcile("The printers on level two are broken.", "The printer's on level two are broken.")
        self.assertEqual(target, "The printers on level two are broken.")
        self.assertFalse(trail["unresolved"])
        _, trail = self.reconcile("Book the speakers travel.", "Book the speaker's travel.", target="Book the speakers' travel.")
        self.assertEqual(trail["status"], "review")

    def test_a_change_to_words_the_target_takes_out_is_left_to_the_check(self):
        target, trail = self.reconcile("It is on Tuesday, sorry, no, the Wednesday.", "It is on Tuesday, sorry, know the Wednesday.",
                                       target="It is on Wednesday.", category="malformed")
        self.assertEqual(target, "It is on Wednesday.")
        self.assertEqual(trail["status"], "automatic")
        self.assertTrue(any(change["rule"] == "outside-target" for change in trail["changes"]))
        # A word the target keeps is still a change to review, and so is one it moved.
        for heard in ("It is on Tuesday, sorry, no, the Wednesday night.", "It is on Tuesday, sorry, no, the when's day."):
            _, trail = self.reconcile("It is on Tuesday, sorry, no, the Wednesday.", heard, target="It is on Wednesday.", category="malformed")
            self.assertEqual(trail["status"], "review", heard)
        _, trail = self.reconcile("We need the cache cleared.", "We need the cash cleared.")
        self.assertEqual(trail["status"], "review")

    def test_target_list_numbers_keep_their_layout(self):
        target, trail = self.reconcile("Number one restart the phone then wait twenty seconds.", "Number 1 restart the phone then wait 20 seconds.", target="1. Restart the phone.\n2. Wait twenty seconds.", category="list-many")
        self.assertEqual(target, "1. Restart the phone.\n2. Wait 20 seconds.")
        self.assertFalse(trail["unresolved"])


class TranscriptSeedTests(unittest.TestCase):
    def test_the_rules_file_holds_what_the_generator_writes(self):
        self.assertEqual(json.loads(prep.RULES.read_text())["transcript_seeds"], seeds.split(seeds.seeds()))

    def test_a_template_stays_in_one_split_and_a_name_never_starts_a_sentence(self):
        rows = seeds.seeds()
        splits = {split: {row["raw"] for row in found} for split, found in seeds.split(rows).items()}
        for group in {row["group"] for row in rows}:
            homes = {split for split, raws in splits.items() for row in rows if row["group"] == group and row["raw"] in raws}
            self.assertEqual(len(homes), 1, group)
        names = {name for _, name, _ in seeds.MISHEARD}
        for row in rows:
            if row["category"] != "recognition" or row["raw"] == row["target"]:
                continue
            for sentence in re.split(r"(?<=[.?!])\s+", row["raw"]):
                self.assertNotIn(sentence.split()[0].strip(",."), names, row["raw"])


class QuarantineTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.dataset = Path(self.scratch.name) / "merged"
        self.data = {split: [example(f"A {split} zebra.", split, split),
                             example(f"A {split} horse.", split + "-b", split)] for split in prep.SPLITS}
        prep.save_dataset(self.dataset, self.data, {"kind": "deep"})

    def audit(self, issues):
        audit = {"kind": "deep", "ready": not issues, "issues": issues, "counts": {},
                 "files": {f"{split}.jsonl": prep.file_digest(self.dataset / f"{split}.jsonl") for split in prep.SPLITS}}
        path = self.dataset / "audit.json"
        path.write_text(json.dumps(audit))
        return argparse.Namespace(dataset=self.dataset, audit=path)

    def test_blocked_rows_are_set_aside_with_their_reasons(self):
        reasons = ["Deep's output guard rejects the target", "ASR changed words; this pair needs a reviewed target"]
        prep.quarantine(self.audit([{"file": str(self.dataset / "train.jsonl"), "line": 2, "reasons": reasons}]))
        self.assertEqual([row["id"] for row in prep.read_rows(self.dataset / "train.jsonl")], ["train"])
        held = prep.read_rows(self.dataset / "quarantined.jsonl")
        self.assertEqual([(row["split"], row["row"]["id"], row["reasons"]) for row in held], [("train", "train-b", reasons)])
        report = json.loads((self.dataset / "preparation-report.json").read_text())["quarantine"]
        self.assertEqual(report["rows"], 1)
        self.assertEqual(report["reasons"], {reason: 1 for reason in reasons})

    def test_rows_derived_from_a_row_set_aside_go_with_it(self):
        parent = self.data["train"][1]
        variant = example("a train horse", "train-b-unpunctuated", "train", family_id=parent["family_id"],
                          provenance={"kind": "derived-unpunctuated", "parent_id": "train-b"})
        sound_alike = example("A train hoarse", "train-b-unpunctuated-sound", "train", family_id=parent["family_id"],
                              provenance={"kind": "synthetic-sound-alike", "parent_id": "train-b-unpunctuated"})
        self.data["train"] += [variant, sound_alike]
        prep.save_dataset(self.dataset, self.data, {"kind": "deep"})
        reason = "Deep's output guard rejects the target"
        prep.quarantine(self.audit([{"file": str(self.dataset / "train.jsonl"), "line": 2, "reasons": [reason]}]))
        self.assertEqual([row["id"] for row in prep.read_rows(self.dataset / "train.jsonl")], ["train"])
        held = {row["row"]["id"]: row["reasons"] for row in prep.read_rows(self.dataset / "quarantined.jsonl")}
        self.assertEqual(held, {"train-b": [reason], "train-b-unpunctuated": [prep.DERIVED],
                                "train-b-unpunctuated-sound": [prep.DERIVED]})

    def test_a_preparation_fault_is_not_set_aside(self):
        options = self.audit([{"file": str(self.dataset / "valid.jsonl"), "line": 1, "reasons": ["duplicate example id"]}])
        with self.assertRaisesRegex(ValueError, "preparation fault"):
            prep.quarantine(options)
        self.assertEqual(len(prep.read_rows(self.dataset / "valid.jsonl")), 2)

    def test_a_dataset_changed_since_its_audit_is_refused(self):
        options = self.audit([])
        prep.write_rows(self.dataset / "test.jsonl", self.data["test"][:1])
        with self.assertRaisesRegex(ValueError, "changed since the audit"):
            prep.quarantine(options)


class ScoringTests(unittest.TestCase):
    def test_a_word_match_cannot_hide_case_and_question_errors(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            source = example("Are the Macs ready?", "case", "test", target="Are the Macs ready?")
            prep.write_rows(root / "test.jsonl", [source])
            measurement = {"results": [{"id": "case", "category": "unchanged", "raw": source["raw"], "target": source["target"], "shown": "are the macs ready."}]}
            (root / "measured.json").write_text(json.dumps(measurement))
            options = argparse.Namespace(data=root / "test.jsonl", measurements=root / "measured.json", output=root / "score.json")
            prep.score(options)
            counts = json.loads(options.output.read_text())["overall"]
            self.assertEqual(counts["meaning"], 0)
            self.assertEqual(counts["words"], 1)
            self.assertEqual(counts["capitals"], 0)
            self.assertEqual(counts["question_marks"], 0)
            measurement["results"][0]["shown"] = "Are the Macs ready?"
            (root / "measured.json").write_text(json.dumps(measurement))
            prep.score(options)
            self.assertEqual(json.loads(options.output.read_text())["overall"]["meaning"], 1)
            measurement["results"][0]["target"] = "Are the macs ready?"
            (root / "measured.json").write_text(json.dumps(measurement))
            with self.assertRaisesRegex(ValueError, "do not match"):
                prep.score(options)
            measurement["results"][0]["target"] = source["target"]
            measurement["results"] = []
            (root / "measured.json").write_text(json.dumps(measurement))
            with self.assertRaisesRegex(ValueError, "exactly one"):
                prep.score(options)
            source["review_required"] = True
            prep.write_rows(root / "test.jsonl", [source])
            with self.assertRaisesRegex(ValueError, "review-required"):
                prep.score(options)


if __name__ == "__main__":
    unittest.main()
