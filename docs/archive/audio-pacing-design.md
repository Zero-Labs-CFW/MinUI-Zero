# Audio + frame pacing — instrument first, rewrite behind a flag (device-gated)

`docs/project-direction.md` §3 is explicit that this is a separate, *risky* workstream: today
audio is coupled to accidental blocking behavior, and removing it naively makes some cores run
too fast. So this branch does the **safe, measure-first** half now and **scopes** the rewrite —
it does not change the audio path blind.

## Current reality (MinUI base)
SDL pulls from a ring buffer (`SND_audioCallback`); the emulator pushes via `SND_batchSamples`,
which **blocks (waits) when the ring is full** (`tries`/`SDL_Delay(1)` loop). That block is what
paces emulation — convenient, but it means "audio pressure" silently controls game speed. Two
failure modes: **underrun** (ring drains → audible crackle) and **overrun** (ring full → the
emulator is throttled by audio).

## Done on this branch: instrumentation (no behavior change)
- `api.c`: counters at the two points — `underruns` (callback drained) and `overruns`/`wait_ms`
  (batchSamples waited) — plus `SND_getStats()` (counters + current ring fill).
- `telemetry.c` + `bench-analyze.py`: three new CSV columns (`aud_q`, `aud_under`, `aud_over`)
  and an **audio line + an "underruns" release gate** in the analyzer. So a future audio change
  is judged on real underrun/overrun deltas next to mJ/frame and frame-time — we'll *know* whether
  audio is even a problem before touching it. (Counters are a benign cross-thread race — stats only.)

## The rewrite (NOT done — scoped, device-gated, behind a dev flag)
Reference: **`xikteny/MinUI`** `e879176f93` — it backported NextUI's A/V path into the
**monolithic `minarch.c`**, which is exactly our constraint (NextUI itself is modularized `ma_*`).
Donor = LoveRetro/NextUI (**GPLv3** — attribute; lifted lines are GPLv3). Sequence:
1. **Frame limiter independent of audio blocking** (wall-clock pace). *Prerequisite* — it's the
   safety net that lets us remove audio-blocking pacing without games running wild.
2. **libsamplerate resampler + dynamic rate control** (bounded correction) to match emulator
   output to the device rate smoothly; preallocated buffers; underrun/overrun recovery.
3. Handle **59.94 / 60 / PAL** and **per-core timing exceptions**.
4. **Audio device close/reopen across suspend** (ties into deep sleep).

### Required-reading risks before any of that ships
- **PR #31 (upstream, unmerged):** removing audio-blocking pacing made **PCSX-ReARMed run too
  fast** in FMV/menus. → the frame limiter (step 1) is mandatory, and PS1 must be tested separately.
- **NextUI `fd77edfa`:** resampler **output-buffer memory leak** — port the *later* fixes, not just
  the feature commit.
- **xikteny `1ef0430b0e`** (fast-forward audio deadlock) and **`cbb48f74ea`** (warbly audio on the
  Video sync mode) — known follow-ups to carry.

## Policy (from project-direction §3)
- Preserve the known-stable upstream audio path; the new path lands **behind a build/dev flag**,
  default OFF.
- Validate on-device with the benchmark harness (now audio-aware): no new underruns, no runaway
  speed, no drift, no pacing regression — across NES/SNES/GBA/PS1, FMV, menus, fast-forward, and a
  suspend/resume cycle — before the flag flips on.

## Decisions
- **D1 — Instrument before rewriting.** The measurable half ships now; the risky half is gated on
  the data this instrumentation produces.
- **D2 — Frame limiter is the prerequisite**, not an afterthought — it's the PR-#31 safety net.
- **D3 — Dev-flag + per-core validation**, attribute xikteny/NextUI, carry the later fixes.
