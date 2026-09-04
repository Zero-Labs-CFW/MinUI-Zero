# CLAUDE.md — MinUI Zero: performant/efficient MinUI fork for the TrimUI Brick

> **Name: MinUI Zero** (chosen 2026-07-01) — "drive every unused rail to zero." A fork of
> `shauninman/MinUI`. The name lives in `README.md`; internal files/identifiers are **not** renamed
> for branding (keeps upstream merges clean) — the `ZERO_*` env flags are the only Zero-branded symbols.

## What this is
A fork of MinUI focused on **performance through efficiency** on the TrimUI Brick
(`tg5040` platform, Allwinner A133P). The thesis: run each emulated system at the **lowest
CPU clock that still holds its target frame rate**, so the device stays cool and sips power.
This is *not* a feature fork — it's the opposite. NextUI is the feature-rich/GL fork; this
one is the distilled, runs-cold one.

## Scope — **`tg5040` is the fork** (TrimUI Brick + TrimUI Smart Pro); `miyoomini` is a secondary port
The thesis is A133P-specific (cpufreq/OPP/thermal/PMIC), so `tg5040` is the only platform that
carries it and the only one that ships as a real release. `make` still defaults to
`PLATFORMS = tg5040`; a bare `make miyoomini` is rejected on purpose.

**`miyoomini` (Miyoo Mini Plus, SigmaStar SSD202D) is a second, experimental platform** — built,
running, and shipped as a supported (but newer, less-proven) platform, NOT a second first-class
target. Build it explicitly: `make PLATFORMS=miyoomini miyoomini`. Its artifacts are no longer
`-alpha`-stamped (dropped 2026-09-04: the ports fix more stock MinUI bugs than they lack, so the
label undersold them; per-device maturity nuance lives in the README sections instead).
MEASURED and worth knowing before spending effort there: **the efficiency thesis does not transfer**
(~1% — on that SoC the CPU is not where the power goes), so MMP work is parity/polish, not thesis
work. Deep sleep is proven impossible there. Anything that costs the Brick to serve the MMP loses.

Every other MinUI platform is frozen under `workspace/_unmaintained/` — present for history and
upstream merges, **not built or supported**. `workspace/macos/` stays as the zero-hardware dev/test
platform (launcher build + harnesses), not a device. Don't re-add a device without doing that
device's full bring-up (recon + per-SoC wiring) — the MMP port is what that costs.

## Multi-platform parity — features/settings/paks stay in sync unless divergence is EARNED
With more than one platform, drift is the default failure mode, and it happens silently: tg5040
grew systems/settings over months while the MMP kept the pak set from its port date, so 7 systems
sat unlaunchable with their cores already shipping (caught 2026-07-27). The rules:

- **Parity is the default.** A feature, setting, default.cfg value, pak, or core added to one
  platform gets added to the other in the same change — or gets an explicit written reason why not.
  "Didn't think about the other platform" is drift, not a decision.
- **Divergence must be earned by hardware and documented at the point of divergence** (comment in
  the pak/cfg, plus a D-log entry when it's a real decision). Current earned divergences:
  - *Scaling defaults* — MMP GB/GBC/FC ship `Native`, tg5040 ships `Aspect`: panel geometry
    (640×480 makes NES-at-Aspect 2.5× horizontal → scroll shimmer; 1024×768 gives a clean 4.0×).
  - *Audio architecture* — MMP uses the MI_AO daemon + `MINARCH_PRELOAD` shim; tg5040 does not.
  - *Deep sleep* — Brick/SP only (proven impossible on the MMP SoC). *GPU-dark menu* — Brick-only
    (SP panel scans the GLES layer). *Present-skip (`ZERO_DUP_SKIP`)* — qualified on the GLES path
    only; not enabled on the MMP fbdev path until measured there.
  - *Governor brackets* (`MINARCH_FMIN/FMAX`) — per-SoC receipts, never copied across platforms.
    An unmeasured bracket is labelled unmeasured in the launch.sh.
- **Sync by comparison, not memory.** `workspace/all/` is shared automatically — a change there
  hits every platform (verify both; regressing the Brick is the worst outcome). Everything under
  `skeleton/SYSTEM/<platform>/` and the per-platform makefile blocks/`cores/` is duplicated and
  WILL drift. When touching one platform's copy, diff the other: pak sets, default.cfgs, makefile
  core lists, core patches (equivalent modulo the platform block — hash pins must match).
- **Changes that span files ship atomically per platform.** A producer/consumer pair (e.g.
  MinUI.pak sets `MINARCH_PRELOAD`, all 8 emu paks consume it) deployed partially = a broken
  device that looks healthy. `tools/deploy-miyoomini.sh` syncs the whole payload by md5 for
  exactly this reason — never hand-pick files.
- **Config-default changes need the saved-cfg migration** (minarch `cfg_stale_keys`): saved cfgs
  carry every option, so a shipped-default change is silently defeated by old saves unless an
  entry migrates it — see the table's comment for the rules (per-entry version, only where the
  shipped chain resolves to the new value).

## North star / non-negotiables
- **Cool + efficient is the whole point.** Every change should serve "lowest clock that holds
  frame rate." If a change adds heat, idle power, or resident memory without earning it, don't.
- **Default to MinUI's lean software (RGB565) render path.** Fix tearing the cheap way first
  (page-flip + double-buffer / NEON scalers, referencing MyMinUI). GLES is **benchmarked, not
  auto-rejected** — adopt only if it wins on *total-device* power/temperature, not CPU% (it
  keeps the GPU lit, which usually loses). See `docs/project-direction.md` §2.
- **"Minimal" describes the UX, not the implementation.** Substantial internal change is fine
  where it earns thermals, gameplay, frame pacing, suspend/save reliability, or crash
  resistance. User-facing features are still weight — no box art, WiFi/NTP, Pak Store,
  RetroAchievements, ambient-LED, overlays. Authoritative direction + roadmap:
  **`docs/project-direction.md`** (it supersedes this file where they differ).
- **Quality gameplay outranks the no-overclock rule** (amended 2026-07-28 by Dan; was "never
  overclock"). The discipline that replaces the ban:
  - *Root-cause first.* An overclock is never the first fix. The Brick BR2 saga is the template:
    a 46% deficit that looked clock-shaped was a serialization bug (D48), fixed at stock.
  - *OC must be earned by measurement*, never vibes: a receipt showing the target rate is genuinely
    unreachable at the verified-stock ceiling. The receipt must be a MATCHED CLOCK A/B (run the
    workload at both clocks and compare), never a clock inferred by scaling a work metric — MMP PS1
    was briefly cited here as the worked example on exactly that inference ("p95 needs ~1.5 GHz")
    and a pin-verified 1200-vs-1488 A/B then moved it 0%. There is currently NO earned OC anywhere
    in this fork; treat any p95-derived "needs N MHz" as a hypothesis, not a receipt.
  - *Stock stays the default* wherever stock holds rate. OC ships per-system (pak-scoped),
    documented at the point of use, after an on-device thermal/stability soak.
  - The governor's cap still defaults to the highest *verified-stock* OPP; on tg5040 do not use
    2.0 GHz unless evidence proves it stock (nothing there needs it — see D48).
- **Never fabricate device values.** Real OPP steps / thermal-zone paths come from the hardware
  (`tools/brick-recon.sh`); query the OPP table at runtime. Until measured, use the
  **clearly-labeled assumptions** in `docs/thermal-governor-design.md` (safe by construction,
  not hidden guesses).

## Hardware (target platform = `tg5040`)
- **SoC:** Allwinner A133P, quad-core Cortex-A53. MinUI's tg5040 code drives it via the
  `userspace` cpufreq governor, writing kHz to
  `/sys/devices/system/cpu/cpu0/cpufreq/scaling_setspeed`.
- **Known reference clocks (read from tg5040 source, not assumed):** 600 / 1200 / 1608 / 2000
  MHz = menu / powersave / normal / performance. (2.0 GHz is a mild OC over the 1.8 GHz stock.)
- **GPU:** PowerVR GE8300 — irrelevant here (software render path).
- **Display:** 1024×768 IPS. **RAM:** 1 GB.
- The Brick and the TrimUI **Smart Pro** share the `tg5040` platform. (The plain Smart is
  `trimuismart` — different platform; ignore it.)

## Architecture — where things live (verify by grepping; line numbers are approximate)
- `workspace/all/minarch/minarch.c` — the libretro frontend + main run loop. **The governor
  tick goes here.** Already measures frame pacing around `GFX_flip` / `FRAME_BUDGET`.
- `workspace/all/common/api.c` — `GFX_flip` / `GFX_sync` / `PLAT_vsync` (frame pacing,
  `gfx.vsync = VSYNC_STRICT`); `PWR_*` (sleep/power); `SND_*` (audio).
- `workspace/all/common/scaler.c` / `scaler.h` — **our software RGB565 scalers.** This is the
  render path to keep/optimize.
- `workspace/all/common/api.h` — `CPU_SPEED_*` enum (~L298); `#define PWR_setCPUSpeed
  PLAT_setCPUSpeed`.
- `workspace/tg5040/platform/platform.c` — `PLAT_setCPUSpeed` (~L546, the freq write),
  `PLAT_blitRenderer` (~L367), `PLAT_flip` (~L373), `PLAT_setVsync`/`PLAT_vsync`.
- `workspace/tg5040/install/boot.sh` — sets `userspace` governor + clock at boot.
- `workspace/tg5040/cores/patches/` — per-core build patches (gpsp, mgba, pcsx_rearmed,
  picodrive, snes9x2005_plus, fceumm, gambatte, …). Start core tuning from these.
- `workspace/macos/` — **dummy desktop platform** (its own notes say so): builds the launcher
  on macOS under AddressSanitizer, no cores, stubbed input. Our zero-hardware playground for
  logic — useless for thermal/perf (no real clocks or heat).

Full three-way file map (incl. NextUI/MyMinUI equivalents): **`docs/architecture-map.md`**.

## Reference forks (git remotes — borrow freely)
This is a community fork scene — borrow and adapt code from any of these freely; keep
attribution as a courtesy. The only real friction is technical, not legal: NextUI modularized
`minarch.c` into `ma_*` modules, so its code rarely applies cleanly as a patch — prefer the
leaner forks when a technique exists in more than one.
- `upstream` = `shauninman/MinUI` — the base.
- `mymin` = `Turro75/MyMinUI` — **best reference for the lean tear-free software render path**
  (NEON + multicore + double-buffer, no GL).
- `nextui` = `LoveRetro/NextUI` — reference for the **suspend-to-RAM / deep-sleep overheat fix**
  and the dynamic-governor idea (its governor delegates to kernel governors, which can't do
  "lowest clock that holds frame rate" — see our closed-loop design instead).
- `zhaofengli` = `zhaofengli/MinUI` (`deep-sleep` branch) — the original, minimal deep-sleep
  implementation against **stock MinUI `PWR_*`** (maps ~1:1 to our tree). Best deep-sleep ref.

```
git remote add upstream   https://github.com/shauninman/MinUI.git
git remote add nextui     https://github.com/LoveRetro/NextUI.git
git remote add mymin      https://github.com/Turro75/MyMinUI.git
git remote add zhaofengli https://github.com/zhaofengli/MinUI.git
git fetch --all
```

## Build & dev loop
**Zero-hardware (do this first — governor logic):** macOS dummy platform. Builds the launcher
under ASan; good for logic/crashes, *not* thermal/perf.
```bash
brew install sdl2 sdl2_image sdl2_ttf
cd workspace/all/minui && mkdir -p build/macos
gcc minui.c -o build/macos/minui -I. -I../common/ -I../../macos/platform/ \
  -I/opt/homebrew/include -L/opt/homebrew/lib \
  ../common/scaler.c ../common/utils.c ../common/api.c ../../macos/platform/platform.c \
  -DPLATFORM=\"macos\" -DUSE_SDL2 -Ofast -std=gnu99 \
  -ldl -lSDL2 -lSDL2_image -lSDL2_ttf -lpthread -lm -lz \
  -fsanitize=address -fno-common \
  -Wno-tautological-constant-out-of-range-compare -Wno-asm-operand-widths
./build/macos/minui
```
**Flashable Brick build (needs Docker running):**
```bash
make tg5040                 # builds tg5040 in MinUI's docker toolchain; zip → ./releases/
make shell PLATFORM=tg5040  # drop into the toolchain container
```
**On-device iteration:** MinUI runs from SD + SSH, so no reflashing per change. ALWAYS deploy with
`sh tools/deploy-device.sh <platform> root@<ip> -i ~/.ssh/tg5040_dev`. It md5-syncs EVERY staged
payload root (`.system/<platform>` and `Tools/<platform>`), refuses a build older than the working
tree, and verifies afterwards. Do NOT scp individual files: this line used to say "scp the rebuilt
minarch.elf / pak", which contradicts the never-hand-pick rule above and caused exactly that bug on
2026-08-30 (a hand-picked deploy left stale `confirm.elf`/`say.elf` on a Brick Pro, so three Tools
rendered at Smart Pro resolution while the menu and games looked perfect).

## Direction & status — see `docs/project-direction.md` for the authoritative plan
Five pillars: (1) thermals/battery, (2) perfect gameplay **at the lowest clock that achieves it**
(stock preferred; OC only with a receipt — see the amended rule above), (3) frame
pacing / tear-free, (4) suspend/save reliability, (5) crash resistance. Staged roadmap +
benchmark/acceptance gates live in `docs/project-direction.md`.

Shipped + on-device-validated (2026-07-01, on `integration`, build `MinUI-20260701-2`):
- **GPU-dark menu** — software present to `/dev/fb0` (`PLAT_flipFB`, env `ZERO_FB_PRESENT` on by
  default in `MinUI.pak/launch.sh`); the PowerVR domain suspends at the menu (~26°C, snappy).
- **Closed-loop governor** — hybrid model live: frame-aware controller sets a `scaling_max_freq`
  ceiling, `schedutil` picks beneath it, measured OPP values, capped at the verified-stock 1.8 GHz OPP
  (2.0 GHz OC dropped). **Race-to-idle** (`DECISIONS` D14): the ceiling must not force `schedutil` below
  the clock where it finishes-the-frame-and-idles. ~4-5°C cooler than stock, validated GBC→PS1.
- **Deep sleep** — validated on-device (33→27°C, clean resume). **ON by default** (2026-07-01); opt-out
  via the Deep Sleep tool (`disable-deep-sleep` flag).
- **Radios + LEDs off** by default (`boot.sh`); **QoL** #4 (bail on failed `core.load_game`) + #6
  (`SET_SYSTEM_AV_INFO`/`SET_GEOMETRY` re-sync) in `minarch.c`; `-O3` pinned cores; drift-free pacer.
- **Measured:** **~7.7h** battery on GB/GBC post-optimization (2026-07-02 re-baseline: 390 units/h,
  461 min est; was ~6h pre-sweep); CPU OPP floor = **408 MHz** (no lower step — so a
  sub-408 sleep clock is impossible; `schedutil` already idles there).
- **GPU-dark GAMES: tested → SHELVED** — software-scale-to-fb0 (`ZERO_FB_GAME`, `PLAT_flipFB_game`)
  renders + GPU suspends + smooth (row-caching, 72% CPU), but a clean drain A/B = **exact break-even vs
  GLES** (~6h) → games keep GLES, GPU-dark is **menu-only**, flag off by default. Only real-win path =
  the DE hardware scaler (`/dev/disp` layer — no GPU *and* no CPU scale), a research project.

**Optimization sweep COMPLETE (2026-07-01, D21/D22 + probes)** — shipped: frontend `-O3 -mcpu=cortex-a53`
(was accidentally `-Os`; −3.3% CPU), keymon blocking `poll()` + Brick hardware-mute discovery (65→**0**
idle wakeups/sec), audio device closed in faux-sleep (~7%→0), targeted `fsync` (no global-sync stalls),
`noatime`, model-detect cache. Closed with on-device evidence (don't re-chase): DE `/dev/disp` scaler
(kernel exposes no layer API), DRAM rail (no driver bound), GPU rail (auto-suspends already), MMC-PM
(already auto), vblank (sleeps, no spin), picodrive ARCH (no aarch64 M68K JIT), FMIN floors (D21: 408
saturates for zero win), core hotplug (D22: exact break-even). Remaining: battery re-baseline after the
sweep; DTB undervolt is the only big lever left (high effort/risk, deferred). See
`docs/zero-efficiency-roadmap.md` + `docs/qol-backlog.md`.

**2026-07-04 update — v1.0.0 live, BOTH devices validated (D24-D33):** generation-rate slip detector +
predictive sink gate (D24/D28); Smart Pro fully brought up: sweep matches Brick, deep sleep 50-cycle
certified, menu layout fixed (PADDING 40→10, 10 rows), audio saga resolved (D33 — DAC raw 160 = 0dB on
BOTH devices, digital volume reversed on BOTH; stock semantics correct, don't "fix" from dB tables);
own dropbear ships in .system (SP firmware has no sshd; dynamic build only — static segfaults);
**GPU-dark menu is Brick-ONLY** (SP panel scans the GLES layer, not fb0 — content ≠ scanout, D-logged);
card hygiene sweeper + no-index markers ship in base zip. Battery 7.5h figure = Brick-measured.
Dev access: Brick root@.90:22 (stock sshd), SP root@.249:2022 (our dropbear); deep sleep kills SSH
after 2 min idle — have Dan power-tap; after `killall keymon.elf` RESTART it manually.

## Working rules (these complement the global ~/.claude/CLAUDE.md)
- **Read before edit.** Open the actual file and grep the symbol first; the line numbers in
  these docs are approximate.
- **No fabrication.** Mark every hardware assumption; never present an assumed value as measured.
- **Scope discipline.** One subsystem per branch. Keep `main` clean tracking `upstream`; work on
  feature branches (e.g. `feat/thermal-governor`).
- **Stay lean, stay software-rendered** unless explicitly told otherwise in chat.
- **Borrow freely.** This is a community fork scene — adapt code from the reference forks as
  needed; keep attribution as a courtesy. Don't spend effort on license analysis or clean-room
  reimplementation.
- **Log + keep working documents in `.notes/`** (gitignored, at the repo root). As you work,
  write plans, triage notes, decisions and their rationale, Codex review prompts/responses,
  benchmark and measurement data, build logs, and design docs there — anything that isn't
  shipping code. Do it as you go, not just at the end; give each a clear or dated name and tell
  Dan the path. Never keep working state only in chat, or on a feature branch/worktree where a
  cleanup could lose it — `.notes/` persists across branch and worktree churn, so it's the
  durable home for it. Keep it tidy enough to find things later.
