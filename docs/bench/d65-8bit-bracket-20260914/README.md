# D65: 8-bit clock bracket A/B, pinned 1008 MHz vs 600-1008 MHz (2026-09-14, Brick)

Receipt for the change shipped in v1.7.6 (D65 in [`docs/DECISIONS.md`](../../DECISIONS.md), commit `001134d5`): the six 8-bit systems (GB, GBC, NES, SMS, GG, PCE) moved from a pinned 1008 MHz ceiling to a 600-1008 MHz bracket under the closed-loop governor. This is a **Zero vs Zero** comparison and is not part of the NextUI 1:1 set.

## Setup

- One TrimUI Brick, WiFi off, discharging 100% to 90%, 13:41 to 14:47 on 2026-09-14.
- Same card and build as the [1:1 sweep](../nextui-1to1-20260914/) run that morning (a v1.7.5-era build, undervolt enabled on that card).
- Arm A (pin): the shipped 8-bit paks, `max0=1008000` on every run. Arm B (bracket): the same paks with `MINARCH_FMIN=600000`, `max0=600000` on every run. Eight valid runs; the arm was confirmed from each run's header.
- Workloads: Zelda (GBC) and Gradius (NES) attract demos. Raw: `raw/bracketab/`.

## Result: bracket holds rate, sits at 600

| arm | game | clock, steady | fps (MEASURE) | under/s | dup/s | CPU °C | irq/s | launch |
|---|---|---|---|---|---|---|---|---|
| pin 1008 | Zelda | 997 (at 1008: 97%) | 60.3 | 0.00 | 0.00 | 31.7 ± 0.5 | 2054 | 1.05 s |
| bracket 600 | Zelda | 624 (at 600: 92%) | 60.3 | 0.00 | 0.00 | 30.9 ± 1.9 | 1738 | 1.04 s |
| pin 1008 | Gradius | 1002 (at 1008: 97%) | 60.3 | 0.00 | 0.00 | 36.3 ± 0.2 | 2946 | 0.95 s |
| bracket 600 | Gradius | 625 (at 600: 92%) | 60.2 | 0.00 | 0.00 | 36.0 ± 0.6 | 2470 | 0.98 s |

`fps` is the core's generation rate (MEASURE, Zero-only); `under/s` is audio underruns per second; `dup/s` is mailbox-starvation duplicates. No sub-60 episodes, no under-budget frames, never present-starved, launch unchanged, and the present-skip unique-frame rate was identical in both arms (24.4 and 55.5 per second). The loop sank the ceiling to 600 immediately and held it.

## What it buys, stated plainly

- Consistency: the six 8-bit systems now float on a bracket like GBA, MD and SNES, and settle at 600 MHz.
- 15-16% fewer interrupts per second at 600.
- 0.3-0.8 °C cooler, which is inside the run-to-run spread. Not a thermal headline.
- Battery: 8-minute windows are inconclusive (mV/h is noisy and gauge percent is quantized). This matches the campaign-level finding that governor strategy barely moves gameplay drain on this SoC.
- CPU use rises at the lower clock (Gradius 14.4% to 17.8%) with large headroom left.

## Note on the later drain

The bracket paks stayed on the card after this A/B, so the evening [1:1 drain](../nextui-1to1-20260914/) ran the bracket configuration, not the pinned one. Keep the two receipts separate.
