#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import sys
import unittest

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("timing", Path(__file__).with_name("h700-boot-timing.py"))
timing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(timing)
ID = "42248cd7-52eb-4dd9-88cc-a261d8037b59"
RECEIPT = f"v1 boot={ID} raw_ns=2345678901\n"
STAGE = f"2026-11-18 pre 0.600 post 2.000 total 2.600 boot={ID} | frontend-start 2.00  \n"


class TimingTests(unittest.TestCase):
    def test_same_boot(self):
        self.assertEqual(timing.measure(RECEIPT, STAGE)["reset_to_flip_seconds"], "2.945678901")

    def test_other_boots_ignored(self):
        other = STAGE.replace(ID, "00000000-0000-0000-0000-000000000000")
        self.assertEqual(timing.measure(RECEIPT, other + STAGE)["boot_id"], ID)

    def test_invalid_receipts(self):
        for value in ("", RECEIPT.rstrip(), RECEIPT + "x", RECEIPT.replace("2345678901", "0"),
                      RECEIPT.replace("2345678901", "-1"), RECEIPT.replace("2345678901", str(2**64)),
                      RECEIPT.replace(ID, "bad"), "x" * 113):
            with self.subTest(value=value), self.assertRaises(ValueError):
                timing.measure(value, STAGE)

    def test_missing_ambiguous_or_inconsistent_stage(self):
        for value in ("", STAGE + STAGE, STAGE.replace(ID, "00000000-0000-0000-0000-000000000000"),
                      STAGE.replace(f" boot={ID}", ""), STAGE.replace("total 2.600", "total 3.600")):
            with self.subTest(value=value), self.assertRaises(ValueError):
                timing.measure(RECEIPT, value)

    def test_display_before_start(self):
        with self.assertRaises(ValueError):
            timing.measure(RECEIPT.replace("2345678901", "1000000000"), STAGE)

    def test_wrong_stage_or_malformed_duplicate(self):
        for value in (STAGE.replace("frontend-start", "picker"),
                      STAGE + STAGE.replace("total 2.600", "total ?"),
                      STAGE.replace("frontend-start 2.00", "frontend-start 2.00 frontend-start 2.01")):
            with self.subTest(value=value), self.assertRaises(ValueError):
                timing.measure(RECEIPT, value)

    def test_rounding_boundary(self):
        self.assertEqual(timing.measure(RECEIPT, STAGE.replace("total 2.600", "total 2.601"))["endpoint"],
                         "first_published_completed_flip")


if __name__ == "__main__":
    unittest.main()
