# Benchmark receipts

Raw on-device data backing release claims. Naming: date-system-game-device-arm-mode.

- **2026-09-14 Zero vs NextUI 1:1 (Brick)**: [`nextui-1to1-20260914/`](nextui-1to1-20260914/). One Brick,
  seven attract-demo ROMs, NextUI 6.14.0 in all three CPU modes vs a v1.7.5-era Zero, plus menu idle,
  boot, and a single matched drain. Read its README first: it separates the three Zero configurations,
  names every instrument, and records the `late_pm` mislabel (Zero audio underruns, not missed frames).
- **2026-09-14 D65 8-bit bracket A/B (Brick)**: [`d65-8bit-bracket-20260914/`](d65-8bit-bracket-20260914/).
  Zero vs Zero, pinned 1008 MHz vs 600-1008 bracket on Zelda/Gradius: 60 fps held at ~624 MHz, 15-16%
  fewer irq/s, temperature inside spread, battery inconclusive in 8-min windows. Shipped in v1.7.6.
- **2026-07-08 SNES DKC (Brick)**: stacked-threading A/B, DKC attract, 8-min matched windows,
  90s settle, discharging, same gauge region. armA = stock supafaust (own threads only):
  mean 747MHz w/ excursions to 1416, temp 35.3->36.6C rising, cc_delta 90. armB = + frontend
  threading: flat 600MHz all samples, temp 33.3->32.2C falling, cc_delta 30.
- **2026-07-08 BR2 telemetry (Brick)**: 9 min attract under BENCH=1, stock voltages, auto-thread
  verdict "single". Audio underruns 0-6 total (reporter's "choppy audio" not reproduced).
  p95 26ms frames = the game's ~30fps-internal segments (budget-model artifact, not slowdown);
  generation on-rate throughout per governor telemetry.
- Columns (bench-*.csv): t(uptime s), clock(kHz), temp(milli-C), cap(%). RESULT line:
  charge_counter delta over the window + end voltage.
- Columns (telemetry): see workspace/all/common/telemetry.c header line.

## Methodology note (2026-07-08)
All A/B pairs measure ATTRACT/INTRO content, not player gameplay: THPS2/DKC/Aladdin/BR2 run
true engine demos (representative); Yoshi/Mario RPG/AC2 measure intro sequences (coprocessors
active, lighter than player load). Threading DELTAS are robust to this (heavier scenes give
threading more present-path cost to remove); ABSOLUTE floors are attract-mode figures — real
gameplay sits somewhat higher. Player-load verification: THPS2 in-level HUD sessions confirmed
60/60 at the same 1008 floor (D48, 2026-07-09); broader per-game gameplay passes remain future work.
- DIM CAVEAT (2026-07-08): unattended arms ran with the 30s idle dim active after their
  first 30s (both arms equally). A/B comparisons unaffected; absolute cc values = dim-screen.
