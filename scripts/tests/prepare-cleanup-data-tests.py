#!/usr/bin/env python3
"""Regression checks for input integrity, holdouts and measured-ASR provenance."""

import argparse
import copy
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("prepare_cleanup_data", Path(__file__).resolve().parents[1] / "prepare-cleanup-data.py")
prep = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prep)


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

    def test_question_signal_stays_in_all_profiles(self):
        for profile in prep.PROFILES:
            self.assertEqual(prep.transform("You're coming tomorrow? No, Thursday.", profile).count("?"), 1)

    def test_two_item_list_gets_missing_and_wrong_colon_inputs(self):
        source = "Two things we need: the charger and the passport."
        self.assertNotIn(":", prep.transform(source, "missing-separators"))
        self.assertIn("need,", prep.transform(source, "changed-separators"))
        self.assertEqual(prep.normalize(source), prep.normalize(prep.transform(source, "missing-separators")))

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


class MeasuredASRTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.data = {split: [example(f"A {split} zebra.", split, split)] for split in prep.SPLITS}
        prep.save_dataset(self.root / "dataset", self.data, {})
        self.original = self.data["train"][0]
        self.clip = {"id": "clip", "example": self.original, "spoken": self.original["raw"],
                     "audio_sha256": "audio", "tts": {"voice": "Samantha", "rate": 180}}
        prep.write_rows(self.root / "audio.jsonl", [self.clip])
        self.transcript = {"id": "clip", "raw": "a train zebra?", "model": "/pinned/model",
                           "model_config_sha256": "model-config", "audio_sha256": "audio"}

    def merge(self, transcripts, include_synthetic=False):
        prep.write_rows(self.root / "asr.jsonl", transcripts)
        prep.merge_asr(argparse.Namespace(dataset=self.root / "dataset", audio_manifest=self.root / "audio.jsonl",
                                         transcripts=[self.root / "asr.jsonl"], output=self.root / "merged",
                                         include_synthetic=include_synthetic))

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

    def test_audio_from_an_older_dataset_is_rejected(self):
        self.clip["example"] = copy.deepcopy(self.original)
        self.clip["example"]["target"] = "A different target."
        prep.write_rows(self.root / "audio.jsonl", [self.clip])
        with self.assertRaisesRegex(ValueError, "different dataset"):
            self.merge([self.transcript])


if __name__ == "__main__":
    unittest.main()
