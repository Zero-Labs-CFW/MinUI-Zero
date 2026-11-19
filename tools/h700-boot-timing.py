#!/usr/bin/env python3
"""Pair copied H700 receipts by boot UUID; never access a device.

The endpoint is the first published completed-flip receipt, not input-ready
latency or a guarantee of the earliest flip across concurrent processes. The
reset origin inherits bootclock's ARM-counter assumption; physical timing is
still needed to corroborate power-button-to-picture claims.
"""
import argparse
from decimal import Decimal
import json
from pathlib import Path
import re

UUID = r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}"
NUMBER = r"[0-9]+\.[0-9]{3}"
RECEIPT = re.compile(rf"v1 boot=({UUID}) raw_ns=([0-9]{{1,20}})\n")
STAGE = re.compile(rf"[0-9]{{4}}-[0-9]{{2}}-[0-9]{{2}} pre ({NUMBER}) post ({NUMBER}) total ({NUMBER}) boot=({UUID}) \| .*")


def measure(receipt, stages):
    if len(receipt) > 112:
        raise ValueError("oversized display receipt")
    match = RECEIPT.fullmatch(receipt)
    if not match or not 0 < int(match[2]) <= 2**64 - 1:
        raise ValueError("missing or invalid display timing receipt")
    candidates = [line for line in stages.splitlines()
                  if re.search(rf"(?:^| )boot={match[1]}(?: |$)", line)]
    if len(candidates) != 1:
        raise ValueError("need exactly one same-boot frontend-start record")
    row = STAGE.fullmatch(candidates[0])
    if not row or len(re.findall(r"(?:^| )frontend-start [0-9]+(?:\.[0-9]+)?(?= |$)", candidates[0])) != 1:
        raise ValueError("invalid same-boot frontend-start record")
    pre, post, total = map(Decimal, row.group(1, 2, 3))
    if abs(pre + post - total) > Decimal("0.0015"):
        raise ValueError("inconsistent bootclock sample")
    raw = Decimal(match[2]) / Decimal(1_000_000_000)
    if raw < post - Decimal("0.0005"):
        raise ValueError("display precedes frontend-start; incompatible clocks or receipts")
    return {"boot_id": match[1], "endpoint": "first_published_completed_flip",
            "reset_to_flip_seconds": str(pre + raw),
            "linux_raw_seconds": str(raw),
            "bootclock_rounding_bracket_seconds": "0.001",
            "physical_power_button_timing": False,
            "earliest_flip_across_processes_guaranteed": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("receipt", type=Path)
    parser.add_argument("stages", type=Path)
    args = parser.parse_args()
    try:
        print(json.dumps(measure(args.receipt.read_text(), args.stages.read_text()), indent=2))
    except (ValueError, OSError) as error:
        parser.exit(1, f"h700 timing: {error}\n")


if __name__ == "__main__":
    main()
