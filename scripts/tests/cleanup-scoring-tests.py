#!/usr/bin/env python3
"""Checks that the cleanup score counts meaning and required punctuation, and no house style."""

import importlib.util
from pathlib import Path
import sys
import unittest


SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
spec = importlib.util.spec_from_file_location("cleanup_scoring", SCRIPTS / "cleanup_scoring.py")
scoring = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scoring)


class MeaningTests(unittest.TestCase):
    def assertRight(self, shown, target):
        result = scoring.compare(shown, target)
        self.assertTrue(result["meaning"], f"{shown!r} against {target!r}: {result}")

    def assertWrong(self, shown, target, component):
        result = scoring.compare(shown, target)
        self.assertFalse(result["meaning"], f"{shown!r} against {target!r}: {result}")
        self.assertFalse(result[component], f"{shown!r} against {target!r}: {result}")

    def test_a_target_is_right_against_itself(self):
        for target in ("Hi Victor,\n\nThe delivery is booked for Saturday. Can someone be home?\n\nBest,\nUma",
                       "A few things to bring:\n- Some coins for the car park\n- My reading glasses\n\nSafe travels.",
                       "To jump-start it:\n1. Park close by.\n2. Switch off both engines.",
                       "Dr. Ng is in at 9 p.m. Then we leave. Thanks, Sam.",
                       "Kofi said yes ⟦S1⟧ and Ines agreed. ⟦S2⟧",
                       "Open a PR for the U.S. team's follow-up, and I'll review it."):
            self.assertTrue(all(scoring.compare(target, target).values()), target)

    def test_optional_punctuation_counts_neither_way(self):
        for shown, target in (
                ("We need milk, eggs, and bread.", "We need milk, eggs and bread."),
                ("For the next raid I'll play the healer.", "For the next raid, I'll play the healer."),
                ("The build is green, and Priya will deploy it.", "The build is green and Priya will deploy it."),
                ("The venue — the old hall — is booked.", "The venue, the old hall, is booked."),
                ("Sorry for the confusion. The session has moved.", "Sorry for the confusion: the session has moved."),
                ("Sorry for the delay. The build is green now.", "Sorry for the delay, the build is green now."),
                ("Warning: The stairs are wet.", "Warning: the stairs are wet."),
                ("To set it up, first remove the battery. Then select the network.",
                 "To set it up: first remove the battery, then select the network."),
                ("Hi, Victor.\n\nThe delivery is booked.\n\nBest\nUma", "Hi Victor,\n\nThe delivery is booked.\n\nBest,\nUma"),
                ("Hello, Delia. Thanks for dinner.", "Hello Delia, thanks for dinner."),
                ("Bring:\n- some coins.\n- my glasses.", "Bring:\n- Some coins\n- My glasses"),
                ("Thanks for coming. ⟦S1⟧ It meant a lot. ⟦S2⟧", "Thanks for coming. ⟦S1⟧ It meant a lot ⟦S2⟧"),
                ("We won! ⟦S1⟧ Thanks to Uma.", "We won ⟦S1⟧ thanks to Uma."),
                ("The train leaves at nine forty five.", "The train leaves at nine forty-five."),
                ("Dr Ng is in at 9 a.m. tomorrow.", "Dr. Ng is in at 9 a.m. tomorrow."),
                ("No. Nobody called.", "No, nobody called.")):
            self.assertRight(shown, target)

    def test_meaning_and_required_punctuation_count(self):
        for shown, target, component in (
                ("Me and Sam sent it.", "Sam and I sent it.", "words"),
                ("Its ready.", "It's ready.", "words"),
                ("The train leaves at nine.", "The train leaves at ten.", "words"),
                ("I rang delia.", "I rang Delia.", "capitals"),
                ("Sam and i sent it.", "Sam and I sent it.", "capitals"),
                ("Open a pr.", "Open a PR.", "capitals"),
                ("Thanks. cheers, Nikhil.", "Thanks. Cheers, Nikhil.", "capitals"),
                ("The New jerseys are orange.", "The new jerseys are orange.", "capitals"),
                ("Kofi said yes. ⟦S1⟧ and Ines agreed.", "Kofi said yes ⟦S1⟧ and Ines agreed.", "capitals"),
                ("Uma hasn't replied, Yasmin left the keys.", "Uma hasn't replied. Yasmin left the keys.", "sentence_ends"),
                ("Uma hasn't replied Yasmin left the keys.", "Uma hasn't replied. Yasmin left the keys.", "sentence_ends"),
                ("I need to. Go to the shop.", "I need to go to the shop.", "sentence_ends"),
                ("To set it up first: remove the battery.", "To set it up: first remove the battery.", "sentence_ends"),
                ("When you get home. Call me.", "When you get home, call me.", "sentence_ends"),
                ("Bring milk. Eggs and bread.", "Bring milk, eggs and bread.", "sentence_ends"),
                ("Are the Macs ready.", "Are the Macs ready?", "question_marks"),
                ("You asked if it rains? No.", "You asked if it rains. No.", "question_marks"),
                ("No blockers at the moment", "No blockers at the moment.", "line_ends"),
                ("Bring\n- Coins\n- Glasses", "Bring:\n- Coins\n- Glasses", "line_ends"),
                ("Bring: coins and glasses.", "Bring:\n- Coins\n- Glasses", "layout")):
            self.assertWrong(shown, target, component)

    def test_required_commas_are_reported_outside_the_headline(self):
        for shown, target in (("We need milk eggs and bread.", "We need milk, eggs and bread."),
                              ("Thanks Sam.", "Thanks, Sam."),
                              ("Hi Sam the meeting moved.", "Hi Sam, the meeting moved.")):
            result = scoring.compare(shown, target)
            self.assertTrue(result["meaning"], (shown, result))
            self.assertFalse(result["required_commas"], (shown, result))
        self.assertTrue(scoring.compare("When you get home call me.", "When you get home, call me.")["required_commas"])

    def test_an_alternative_target_can_make_an_answer_right(self):
        self.assertFalse(scoring.score_case("Ring me at ten.", "Ring me at 10.")["meaning"])
        self.assertTrue(scoring.score_case("Ring me at ten.", "Ring me at 10.", ["Ring me at ten."])["meaning"])

    def test_a_report_is_scored_and_counted_by_category(self):
        report = {"results": [{"id": "a", "category": "lists", "shown": "Hi Sam.", "target": "Hi Sam."},
                              {"id": "b", "category": "lists", "shown": "hi sam", "target": "Hi Sam."}]}
        summary = scoring.summarize(scoring.score_report(report))
        self.assertEqual(summary["overall"]["total"], 2)
        self.assertEqual(summary["overall"]["meaning"], 1)
        self.assertEqual(summary["categories"]["lists"]["exact_text"], 1)


if __name__ == "__main__":
    unittest.main()
