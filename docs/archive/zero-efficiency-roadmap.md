# MinUI Zero — how we actually beat NextUI on cool + efficient

Working name: **MinUI Zero** (drive every rail to its zero/ground state). The CPU-governor fight with
NextUI is a *tie* (both `schedutil`, we converged — see `nextui-comparison.md`). To beat them we stop
fighting on CPU clock and win on **total-device power**: the rails NextUI leaves on that Zero turns off.

## Measurement is now UNBLOCKED (2026-06-30)
`current_now` is dead on the AXP2202, but **`charge_counter` works** (`/sys/class/power_supply/axp2202-battery/charge_counter`
= 2340, `charge_full` = 3000, `status` = Discharging, `voltage_now` ≈ 3.84V). Tracking `charge_counter`
drop over a fixed window gives a real **drain rate** → we can finally measure efficiency and validate
every change below (energy ≈ Δcharge × voltage). No more optimizing blind.

## 2026-07-01 — what's actually shipped now (supersedes stale lever statuses below)
- **GPU-dark MENU: DONE + verified.** Software present straight to `/dev/fb0` (RGB565→XRGB8888, native
  res) — the PowerVR domain SUSPENDS while browsing (owner-confirmed "super fast", 26°C). See
  `PLAT_flipFB` in `tg5040/platform.c`, env `ZERO_FB_PRESENT`, on by default in `MinUI.pak/launch.sh`.
- **GPU-dark GAMES: proven possible, but BORDERLINE (needs NEON).** Headroom is real — the GPU sits
  `active` **~93% of a trivial GB game** at 702 MHz just to upscale 160×144. **Prototype built + tested**
  (`ZERO_FB_GAME`, `PLAT_flipFB_game` in `platform.c`, commit `33b5e6e`): it **renders correctly and the
  GPU domain DOES suspend during play** ✅ — but the scalar nearest-neighbor scale to 1024×768 @ 60fps
  cost ~1 core (choppy); a **row-caching** optimization (scale each source row once, `memcpy` to identical
  dst rows) cut it to **72% CPU — smooth, no tearing** (owner-confirmed). **Clean drain A/B, GPU verified
  suspended the whole 15-min window: EXACTLY break-even — 4%/15min = ~6h, identical to GLES.** The
  software-scale CPU cost *precisely offsets* the GPU power it saves → net zero (matching the ~1-2°C
  thermal wash). **DECISION: SHELVED** — zero net gain for 72% CPU + a per-launch-flag and an
  in-game-menu-GLES seam. GPU-dark stays **menu-only**; games keep GLES. The only path to a real games win
  would be the **DE hardware scaler** (`/dev/disp` layer — no GPU *and* no CPU scale), a research project.
  Prototype committed (`33b5e6e`+`b1bsz0..`), `ZERO_FB_GAME` off by default. **Measured, not assumed.**
- **Radios OFF: now actually implemented.** This lever was marked "done" below but wifi/BT were in fact
  always-on (OFW `S96wpa_supplicant`). `boot.sh` now kills BT + gates wifi on `enable-ssh`.
- **Deep-sleep: validated on-device + ENABLED** (suspend-to-RAM, 33→27°C, `enable-deep-sleep` flag).
- **CPU OPP floor = 408 MHz** (measured; no lower step) — so a sub-408 "sleep clock" is impossible;
  schedutil already idles there. **Drain audit PENDING** — needs the device charged + unplugged.

## Lever ①  Kill GPU from the present path — the real headline (CORRECTED)
**Reality check (measured):** we are NOT GPU-dark. `minarch` maps `libGLESv2`/`libglslcompiler`/
`libpvrNULL_WSEGL` and holds an open fd to `/dev/dri/renderD128`; the GPU power domain is `active` and
`pll_gpu`/`gpu` clocks sit at **702 MHz**. Emulation + scaling are software (NEON `scaler.c`), but the
**final blit is presented via GLES on the PowerVR GE8300** — same as NextUI (who also add shaders/effects
on top, so they use it *more*, but we are not at zero).

**The Zero move:** replace the GLES present with a **direct KMS/DRM page-flip to the display engine (DE)**
— no GL, no GPU. Then the GPU power domain can suspend and `pll_gpu` gate off. Reference: **MyMinUI**
(`mymin` remote) already does tear-free double-buffered present **without GL** on these Allwinner parts —
this is exactly what its "lean software render path" is. This is the single biggest *achievable* edge over
NextUI on total-device power, and it's structural (they can't drop GL — their whole UI is GPU-based).
- Effort: real (touches `PLAT_flip`/present in `tg5040/platform.c` + SDL video init — the render path).
- Risk: tearing/vsync regressions; mitigated by porting MyMinUI's proven path, not inventing one.
- Payoff: unknown magnitude until measured — but now measurable via `charge_counter`. **Measure first.**

## Lever ②  Radios / LEDs / services off by default — already Zero, keep it
`rfkill` wifi+BT and zero the LEDs at boot (done). NextUI's feature set (WiFi/NTP, Pak Store,
RetroAchievements, ambient LEDs) keeps these rails powered. Continuous idle-power win we already hold.
(Wifi is only up here for dev SSH; a normal install is dark.)

## Lever ③  Core build -O fixes — free, and NextUI has the SAME bug
Core-build audit (`.notes/core-build-audit.md`): all 10 cores are correct aarch64/ARMv8 (NEON baseline);
the 3 heavy cores (gpsp, pcsx_rearmed, picodrive) carry dynarec JIT + NEON and are optimal. But three
cores silently compile at `-O2` instead of their intended `-Ofast`/`-O3` (Makefile last-`-O`-wins merge):
- **snes9x2005_plus** (default SNES) — best win; SNES is CPU-heavy on the A53.
- **fceumm** (default NES) — its `-Ofast` is dead code in an unused `OPTIMIZE` var.
- **mednafen_supafaust** (extra SNES) — same shadowing.
Faster core code = fewer cycles/frame = lower clock to hold fps = cooler. **NextUI's core patches are
byte-identical and carry the same latent bug**, so fixing it is original and puts us ahead. (Caveat:
`-O3` gains are typically a few %, occasionally regress via icache — measure per core with the meter.)

## Lever ④  DRAM/DMC clock cap
Software render needs far less memory bandwidth than GL texturing; `ddr_thermal_zone` is a live rail.
Cap the memory controller lower than NextUI's `dmc_ondemand`. Modest, measurable.

## Lever ⑤  Frame pacing sleeps, not spins
If the vsync/sync path busy-waits to hit frame time it burns CPU for nothing. Block on the flip instead.
(Especially relevant once ① lands and present is a DRM page-flip we can vsync-block on.)

## Lever ⑥  Custom-DTB undervolt — biggest, future
Regulators are read-only at runtime (confirmed). A DTB with undervolted OPPs cuts power at *every* clock
on *every* rail (CPU+GPU+DRAM). Largest single lever, largest effort/risk. Deferred.

## Suggested order
1. ✅ **DONE** — `charge_counter` drain-rate benchmark stood up (`tools/drain-bench.sh`). Baseline
   ~900 mA / ~3.4 W on PS1. Caveat: `charge_counter` quantizes in ~30-unit (1%) steps → use 10-min+
   windows for precise A/B.
2. ✅ **DONE** — core `-O` fixes landed (snes9x2005_plus/fceumm/supafaust `-O2→-O3`), patches
   regenerated + verified, 3 cores rebuilt (`-O3` confirmed in applied source), deployed; optimized
   fceumm boots + runs clean on-device (no miscompile). Measuring the SNES payoff needs a SNES ROM
   (none on the test device) + a 10-min meter window — deferred, not blocking.
3. Prototype the no-GL DRM page-flip present (①) and measure GPU-dark savings — the marquee win.
4. DRAM cap (④) + frame-pacing (⑤) as follow-ons; DTB undervolt (⑥) as the long game.

## 2026-07-01 — SWEEP COMPLETE: final disposition of every lever
- **① no-GL present:** GPU-dark **menu** SHIPPED (`ZERO_FB_PRESENT`, PowerVR suspends, ~26°C).
  GPU-dark **games** measured exact break-even vs GLES → shelved. DE `/dev/disp` hardware-scale layer:
  **probed unavailable** (GET_CONFIG2 returns empty on this kernel; display is legacy fb0-only). CLOSED.
- **④ DRAM cap:** `dramfreq` DT node exists but **no driver bound**, no devfreq class anywhere. CLOSED
  (not tunable on the stock kernel).
- **⑤ pacing spins:** verified minarch sleeps (54% util in-game — a vblank busy-spin would pin ~100%).
  Non-issue. CLOSED.
- **⑥ DTB undervolt:** still the only big lever left. Deferred (effort/risk).
- **Shipped instead (measured):** frontend `-O3 -mcpu=cortex-a53` (−3.3% CPU; was accidentally `-Os`),
  keymon 65→0 idle wakeups/sec (blocking `poll()` + Brick mute is hardware — thread skipped),
  audio device closed in faux-sleep (~7%→0), targeted `fsync`, `noatime`, model-detect cache.
- **Also closed by measurement:** FMIN floors (D21) and core hotplug (D22) — both zero-win.
Next: battery re-baseline post-sweep; then reliability soak (pillars 4/5) — the efficiency chapter is done.
