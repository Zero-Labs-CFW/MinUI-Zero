# MinUI Zero vs NextUI, 1:1 on one TrimUI Brick (2026-09-13 to 09-14)

Raw receipts for the numbers quoted in [`docs/nextui-comparison.md`](../../nextui-comparison.md). Every figure below is tied to the instrument that produced it and the configuration it ran under. Read the Limitations section before quoting anything.

## Scope

- **Device:** one TrimUI Brick (A133P). Same unit, same SD-card reader, same seven attract-demo ROMs, radios off, brightness at minimum, room temperature not controlled.
- **NextUI:** 6.14.0, each of its three CPU modes set through its own settings UI ("Auto" / "Powersave" / "Performance") and verified live against `governor.sh` (auto = schedutil 408-1800 MHz, powersave = conservative 408-1200, performance = 2000 pinned). Runs in `raw/nextui/auto-run/`, `sweep-1/`, `preflight-1/` (mode-honoured checks), `drain/`, `menuidle/`.
- **Zero:** a v1.7.5-era build. The exact commit on the card at test time is **not established** by these logs; treat the build as "v1.7.5 release era", not a specific hash. Runs in `raw/zero/gameplay/` (the fair seven-game sweep, three rotated passes), `drain/`, `menuidle/`.
- **Zero undervolt: ENABLED** in every Zero run here. `raw/zero/gameplay/zero_bloodyroar_20260914-075332.log` line 3 logs `uv: voltage authority armed (8 table entries)` and line 185 `hold thread started (holding 1012500uV)`; the drain log (`raw/zero/drain/zero-drain_bloodyroar_20260914-194802.log`) shows the same, plus a `voltage update failed ... retaining higher rail` at line 1040. The rail history is therefore not a clean constant; "UV enabled" is the honest label.

## Three Zero configurations, kept separate

1. **Fair sweep (morning, 2026-09-14).** 8-bit systems on the then-shipping pinned 1008 MHz ceiling: `raw/zero/gameplay/zero_zelda_20260914-070356.csv` header `max0=1008000`.
2. **D65 bracket A/B.** Zero vs Zero only, pinned 1008 vs a 600-1008 bracket. Separate receipt: [`../d65-8bit-bracket-20260914/`](../d65-8bit-bracket-20260914/).
3. **Drain (evening, 2026-09-14).** The D65 bracket paks were already on the card: `raw/zero/drain/zero-drain_zelda_20260914-184729.csv` header `max0=600000`. The drain is **not** the shipped v1.7.5 configuration.

## Instruments

- **`fpslog.so`** (source: [`tools/fpslog.c`](../../../tools/fpslog.c)), an `LD_PRELOAD` shim on both firmwares. It timestamps *entry* to the present API (`SDL_RenderPresent` on Zero, `SDL_GL_SwapWindow` on NextUI) and emits per second: `presents/s`, `maxgap_ms`, `late` (an inter-present gap over 25 ms), `first_present`. It is not a scanout or content-change instrument: a long gap is not a proven missed vblank, and Zero skips presenting unchanged frames, so `presents/s` is not a frame rate.
- **MEASURE** (Zero only, `ZERO_MEASURE=1`): `fps=X/Y` is the core's generation rate; **`under/s` is audio ring underruns per second, not dropped frames**; `dup/s` counts mailbox-starvation duplicates only.
- **Aggregation:** [`tools/zbench-agg.py`](../../../tools/zbench-agg.py) produced [`aggregate/agg-FAIR-zero-v2-vs-nextui-sweep1.txt`](aggregate/agg-FAIR-zero-v2-vs-nextui-sweep1.txt). **Known error in that file:** its `late_pm` column for Zero was derived from MEASURE `under/s` and labelled as missed frames. Read that column as *audio underruns per minute* for Zero; it is not comparable to the NextUI `late` count. The comparison doc omits it for that reason.
- **Launch timing:** `LAUNCH_UP` is written by the runner before `exec`, and the end is `first_present` (present-API entry). Neither is process-start or first-visible-gameplay instrumentation.
- **Battery:** the Brick's gauge percent and pack voltage from sysfs. There is no current or coulomb counter, so nothing here is an energy measurement.
- **Boot:** `raw/*/boot-times.log`, from each firmware's own `auto.sh` hook.

## What the data supports

- **Menu idle:** Zero ~597 MHz / ~28.2°C vs NextUI ~1522 MHz / ~33.8°C (`raw/*/menuidle/`). Sensor-direct on both; the clearest result in the set.
- **CPU clock on light systems:** Zero ran 41-64% lower clocks than NextUI auto mode across the light-system rows of the sweep (cpufreq sensor, both firmwares). Zero's sweep ceiling for those rows was the pre-D65 1008 MHz pin.
- **Bloody Roar II, two instruments, not one number:** Zero's core generated 60.2 fps (MEASURE) while calling the present API ~34-36 times/s (fpslog; report mean 34.4/s, drain summary 35.7/s). NextUI auto called its swap API 56.1 times/s with late frames. These are different instruments; the present-call shortfall on Zero is unexplained (a possible cause is minarch skipping NULL/duplicate frames before dup-skip, not confirmed). Do not read this as "Zero holds 60 where NextUI holds 56".
- **Launch (first present after runner exec):** sweep ~1.0 s Zero vs ~2.3 s NextUI; in the drain session ~1.1-1.4 s vs ~1.1-1.2 s. The discrepancy between sessions is **unexplained** (the sweep repeats games across passes, the drain runs each once; cache effects are unproven, not ruled out). No universal speedup claim is supported.
- **Battery, one run:** a single matched discharge, both firmwares 100% to ~85%, three games x 30 min: gauge 15 vs 16 points consumed (Zero 9.9 %/h, NextUI 10.6 %/h), pack voltage 119 vs 136 mV/h. Zero ran the post-D65 bracket, UV enabled, Aspect scaling; NextUI ran auto. Multiple variables unmatched; a single unreplicated observation, not a quantified runtime gain.

## Limitations

- One device, one unit of each SD card, uncontrolled ambient.
- Zero build hash unknown from the logs; UV enabled with an imperfect rail history.
- Sweep and drain are different Zero configurations (pre- and post-D65).
- Present-API timing is not frame-visible timing; Zero's present count is not a frame rate.
- Battery: single run, gauge and voltage only, confounded by scaling and the bracket.
- Launch discrepancy between sessions unexplained.

## Files

- `raw/zero/gameplay/`, `raw/zero/drain/`, `raw/zero/menuidle/`, `raw/zero/boot-times.log`
- `raw/nextui/auto-run/`, `sweep-1/`, `preflight-1/`, `drain/`, `menuidle/`, `boot-times.log`
- `aggregate/agg-FAIR-zero-v2-vs-nextui-sweep1.txt` (see the `late_pm` correction above)
- Harness: `tools/fpslog.c`, `tools/zbench-agg.py`, `tools/bench-run.sh`, `tools/drain-bench.sh`, `tools/bench-analyze.py`
