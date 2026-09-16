# MinUI fork survey and implementation direction

**Project:** New performance- and reliability-focused MinUI derivative  
**Target:** TrimUI Brick, Brick Pro and Smart Pro (`tg5040`) as the flagship, plus alpha `h700` (Anbernic RG35XX Plus/H) and `miyoomini`; every other MinUI platform is frozen in `workspace/_unmaintained/` (not built/supported).  
**Survey date:** 2026-06-30

## Purpose

This is not intended to be a lightly modified MinUI build.

The goal is to create a new MinUI-derived system that preserves MinUI's focused,
appliance-like user experience while allowing substantial internal changes wherever they
improve:

1. **Thermals and battery efficiency**
2. **Perfect gameplay without overclocking**
3. **Frame pacing and tear-free presentation**
4. **Suspend, shutdown, and save reliability**
5. **Core compatibility and crash resistance**

"Minimal" describes the user experience, not necessarily the implementation.

Meaningful internal improvements are encouraged. Additional user-facing features are not.
The ideal result requires little or no tuning by the user and automatically chooses the
coolest configuration that preserves correct gameplay.

## Identity — what "Zero" means (added 2026-06-30, per project owner)

This is **not only about coolness.** It is about **radical simplicity** and **an OS optimized to the
max** — and coolness is what *falls out* of doing both well. Three faces of one discipline, and the
name **MinUI Zero** captures all three:

- **Zero bloat** — MinUI's appliance-like simplicity. No feature creep, an instant menu, nothing the
  user must configure. Minimal by conviction, not by omission.
- **Zero waste** — every layer optimized to the metal: `-O3` dynarec cores, lean software render,
  drift-free frame pacing, the closed-loop governor, radios/LEDs/GPU dark when unused. No cycle, watt,
  or byte spent without earning it. The whole stack — boot, kernel governor, render, cores, audio,
  power states — tuned as far as this silicon allows.
- **Zero heat** — the *result* of the first two, not a separate goal. A simple, maximally-optimized OS
  runs cool, sips battery, and stays snappy as a consequence.

**Practical corollary:** optimizations that serve simplicity or efficiency count even when they don't
move the thermometer — a quieter fan, longer battery, or snappier UI are wins in their own right. The
target is not "coldest" narrowly; it is **the leanest, most-optimized OS this hardware can run.**

## Implementation status (2026-07-01) — shipped + on-device validated

The roadmap below is no longer all forward-looking. A large batch shipped this session and was
**validated on a real TrimUI Brick** (build MinUI-20260701-2, branch `integration`). Progress
against the stages, with the authoritative detail in `docs/DECISIONS.md`:

- **Stage 0 (baseline + measurement) — largely done.** `charge_counter` drain meter stood up
  (`current_now` is dead on the AXP2202); reproducible core builds pinned; first energy baseline
  measured (**~6h on Game Boy**). CPU OPP **floor confirmed = 408 MHz** (no lower step).
- **Stage 1 (CPU + power lifecycle) — shipped + validated.** Closed-loop hybrid governor:
  frame-aware `scaling_max_freq` ceiling + kernel `schedutil` beneath it, per-system caps, **no
  overclock**, 408 hardware idle floor. Low-end systems retain a 1008 stock ceiling so schedutil can
  service short GLES present bursts while still idling below it; PS1 rides ~1416–1800. **~4–5°C
  cooler than stock**. Race-to-idle
  lesson learned on-device (**D14/D61**). Some abnormal-exit restore paths
  still partial (see D12 deferred list).
- **Stage 2 (core build audit) — done.** 6 stock cores corrected from silent `-O2` to `-O3`/`-Ofast`
  and pinned to reproducible HEADs; SNES payoff A/B deferred (no ROM on the test unit).
- **Stage 3 (suspend + power reliability) — shipped + validated + enabled.** Deep sleep
  (suspend-to-RAM, ported from zhaofengli) validated on-device (33 → 27°C, clean resume), enabled via
  opt-in `enable-deep-sleep`. Radios + ambient LEDs dark by default at boot.
- **Stage 4 (renderer) — partial.** **GPU-dark menu shipped + validated** (software present to
  `/dev/fb0`, GPU domain suspends while browsing, 26°C). **GPU-dark *games* tested → shelved**
  (measured exact break-even vs GLES — the software-scale CPU cost offsets the GPU power saved).
  DE hardware-scaler (`/dev/disp`) probed unavailable on this kernel; a real games win needs it.
- **Stage 5 (audio + frame pacing) — partial.** Drift-free absolute-schedule frame pacer shipped;
  QoL #6 keeps pacing/scaler synced across mid-run AV-info changes. The audio-path rewrite stays
  instrument-first behind a dev flag (device-gated).
- **Stage 6 (fault tolerance) — partial.** QoL #4 (bail cleanly on failed `core.load_game`) shipped;
  atomic SRAM/RTC/state/config publication and its fault-injection harness are complete (D58).
  Semantic corrupt-data fallback, low-battery emergency handling, and shutdown/unmount validation
  remain open.

---

## Product constraints

### Required

- Preserve MinUI's simple navigation and low-friction resume behavior.
- Run games correctly at their intended speed and cadence.
- Never require overclocking.
- Discover and respect the device's verified stock frequency table.
- Reduce active-play heat and idle power consumption.
- Recover safely from core crashes, failed launches, failed suspend, and interrupted
  shutdown.
- Keep implementation changes modular, measurable, and reversible.
- Prefer automatic per-core or per-system decisions over settings exposed to users.

### Excluded from the initial product

- Themes and visual customization systems
- Artwork-heavy interfaces
- Wi-Fi management UI
- File managers
- Game switchers
- Package stores
- Shader collections
- Screen-effect overlays
- User-facing CPU governor controls
- User-facing threading controls
- Features that increase background activity without improving gameplay or reliability

Internal services may be added when required for power management, suspend, logging, or
hardware stability, but they should remain invisible to the user.

---

## Survey method

The upstream `shauninman/MinUI` fork network was triaged by activity, divergence, stars,
recent commits, and relevance to power, rendering, frame pacing, audio, or reliability.
Approximately 30 active or meaningfully divergent candidates were examined from a much
larger fork network. Most remaining forks appear to be translations, snapshots, personal
mirrors, cosmetic variants, or feature expansions unrelated to the project goals.

The most valuable sources are:

- **Current MinUI:** UX, MinArch model, current Brick support, shutdown fixes, audio fixes
- **LoveRetro/NextUI:** CPU lifecycle, kernel-governor work, suspend, power-off protection,
  audio evolution, ARM/core build fixes
- **Turro75/MyMinUI:** optimized software rendering, NEON, rotation, buffering, selective
  multicore ideas
- **zhaofengli/MinUI:** clean origin of deep-sleep support against stock MinUI APIs
- **frysee/MinUI-EX:** later deep-sleep integration in a MinUI-like tree
- **UnuOS and smaller forks:** failure cases, compatibility warnings, and ideas to avoid

Do not merge any major fork wholesale. Import concepts or isolated changes in small,
reviewable commits and preserve the source repository and commit SHA in the commit message.

---

## Fork landscape

| Fork | Role in this project | Recommended use |
|---|---|---|
| `shauninman/MinUI` | Baseline | Preserve its interaction model, MinArch integration, current Brick support, save/resume behavior, and recent reliability fixes. |
| `LoveRetro/NextUI` | Primary engineering donor | Study and selectively port CPU-governor architecture, CPU lifecycle fixes, suspend, shutdown protection, resampler evolution, memory fixes, and AArch64/NEON build corrections. |
| `Turro75/MyMinUI` | Primary renderer donor | Study and selectively port NEON RGB565 operations, rotation, tile processing, border skipping, buffering, and conditional render threading. |
| `zhaofengli/MinUI` | Deep-sleep origin | Use as the cleanest reference for adding suspend-to-RAM to a stock-MinUI-style power API. |
| `frysee/MinUI-EX` | Secondary suspend reference | Compare later TG5040 integration and edge-case handling. |
| `retronian/UnuOS` | Compatibility caution | Use its disabled paths and crash reports to identify unsafe threading, resize, or post-processing behavior. |
| FinUI and older union-minui forks | Historical reference | Review only for isolated power or performance ideas; do not use as a modern base. |
| Feature-heavy or cosmetic forks | Out of scope | Do not import product-layer features that do not support performance, efficiency, or reliability. |

---

# Architecture direction

## 1. Hybrid frame-aware CPU control

The existing frame-slip or frame-time controller remains a valuable upper-level policy
because it can answer the question that a normal kernel governor cannot:

> What is the lowest performance ceiling at which this game still delivers correct frames?

However, NextUI's kernel-governor work should not be dismissed. The preferred architecture
is a hybrid:

```text
Measured emulation and presentation timing
                |
                v
Frame-aware controller chooses an allowed stock-frequency ceiling
                |
                v
Kernel schedutil selects instantaneous frequency beneath that ceiling
                |
                v
CPU hardware
```

This combines:

- Frame-delivery awareness from the project controller
- Fast kernel-managed transitions
- Reduced userspace frequency-management overhead
- A hard non-overclock ceiling
- Lower clocks during lighter portions of a frame or game

### Important NextUI evidence

Review these commits before implementation:

- `6990d474cabf6c07d80e53140a2ce66760c3f39a`
  - Replaced a userspace CPU-governor loop with kernel governors.
  - Reported a substantial thermal improvement.
- `afb3783de5b017f0f02862a23024bb44ecc4cc75`
  - Changed the Auto policy from `ondemand` to `schedutil` and adjusted caps.
- `e9e91137b6356ce663d5faa054476e7ce19e7b1e`
  - Fixed fresh installs or startup paths that could leave the CPU stuck in Performance.
  - Used Performance only during initialization and explicitly restored the configured
    normal profile.

Do not blindly copy NextUI's three user-facing profiles. Port the infrastructure and
lifecycle handling, then connect it to the project's frame-aware controller.

### Frequency rules

- Query the kernel's available frequencies at runtime.
- Do not hardcode frequency values from another fork.
- Never use 2.0 GHz unless on-device evidence proves it is an officially supported,
  non-overclock operating point for the exact device and kernel.
- Default to the highest verified stock/non-overclock OPP as the absolute cap.
- Record the chosen OPP ceiling and transition decisions in optional debug logging, not in
  per-frame production logs.
- Restore the safe Auto policy after:
  - Core initialization
  - Core exit
  - Core crash
  - Failed launch
  - Resume
  - Shutdown cancellation

### Controller behavior

The controller should:

- Raise the allowed ceiling quickly when sustained frame misses occur.
- Lower the ceiling slowly after a stable interval.
- Use hysteresis to avoid oscillation.
- Treat audio underruns and presentation misses as separate signals.
- Support per-core minimums or exceptions only when benchmarks prove they are needed.
- Never chase emulator fast-forward or uncapped menus as though they were missed gameplay
  frames.
- Avoid a high-frequency polling thread. Prefer timing data already produced by MinArch or
  the presentation loop.

---

## 2. Rendering architecture

MyMinUI is the strongest renderer reference. Because this is a new version rather than a
small patch set, its complete rendering flow may be evaluated, but it should still be ported
incrementally.

### Candidate techniques

- NEON-optimized RGB565 scaling and conversion
- Rotation before scaling, when that reduces processed pixels
- Tile-based rotation or copying
- Skipping known black borders or untouched regions
- Double buffering or correct page flipping
- Better ownership of front, back, and core framebuffers
- Removal of unnecessary intermediate copies
- Conditional render threading
- Core/render synchronization that blocks rather than polls

### Threading policy

Do not expose "Thread Core" or "Prioritize Audio" settings to users.

Use the least expensive rendering path that holds the frame budget:

1. Direct or single-threaded software presentation
2. Single-threaded NEON operations
3. Conditional worker-thread rendering
4. Minimal GLES backend only when it wins total-device measurements

Multicore rendering can increase heat even when it raises FPS. Enable it only for systems,
rotations, or scaling paths that measurably need it. The decision should be automatic and
based on a tested compatibility table or runtime evidence.

### GLES evaluation

GLES should be benchmarked rather than automatically rejected or adopted.

Potential advantages:

- Offloads scaling and rotation from the CPU
- Reduces memory copies
- May provide cleaner presentation synchronization
- May allow a lower CPU ceiling

Potential disadvantages:

- Keeps the GPU active
- Can increase total SoC power despite lower CPU usage
- Adds driver, context, and suspend complexity
- Can introduce shader compilation or presentation stalls

Benchmark at least these paths:

1. Existing software RGB565
2. Optimized single-threaded NEON
3. Conditional multithreaded NEON
4. Minimal nearest-neighbor GLES

Choose using total device temperature, battery draw, frame-time percentiles, and stability,
not CPU utilization alone.

### MyMinUI porting caution

Do not import the renderer as one giant change. Suggested sequence:

1. Establish pixel-perfect reference captures and frame-time baselines.
2. Add optimized primitives with identical output.
3. Optimize rotation.
4. Remove unnecessary copies.
5. Add double buffering/page flipping.
6. Add conditional threading.
7. Evaluate GLES separately.

Each step must be independently benchmarked and revertible.

---

## 3. Audio and frame pacing

Audio is a separate engineering workstream and should not remain coupled to accidental
blocking behavior.

Investigate:

- Nonblocking ring-buffer writes
- Correct handling of 59.94 Hz, 60 Hz, and PAL rates
- Dynamic resampling with bounded correction
- Preallocated resampler buffers
- Audio underrun and overrun recovery
- A presentation/frame limiter independent of audio blocking
- Per-core timing exceptions
- Audio-device close/reopen across suspend
- PS1 FMV and menu timing
- Fast-forward behavior

### Important evidence

- Upstream MinUI PR #31 experimented with dynamic resampling, but PCSX-ReARMed could run
  too fast in some videos or screens when audio blocking no longer constrained execution.
  Do not port the resampler without an explicit frame limiter and core-specific testing.
- NextUI commit `fd77edfa50eccce8363e6de00064366a7c982338` fixed a leaked resampler output buffer.
  Any resampler port must include the later memory-management and stability history, not
  just the original feature commit.

### Initial policy

- Preserve the known-stable upstream audio path while CPU and renderer work is validated.
- Instrument underruns, queue depth, and pacing without logging every frame.
- Introduce a new audio path behind a build-time or developer-only switch.
- Test PS1 separately from simpler systems before making it the default.

---

## 4. Suspend-to-RAM and idle power

Deep sleep is a first-class capability for this new version, but it is primarily an idle
power and appliance-behavior improvement rather than an active-gameplay optimization.

### Primary reference

Use `zhaofengli/MinUI`'s `deep-sleep` branch as the clean starting point because it was
written against stock MinUI-style `PWR_*` APIs. Compare it with MinUI-EX and NextUI for
later edge cases and TG5040 behavior.

### Desired behavior

```text
Short power press
    -> immediate screen/audio-off faux sleep
    -> after a short internal delay, suspend-to-RAM
    -> wake restores display, audio, input, governor, and game state
    -> prolonged inactivity, critically low battery, or repeated suspend failure
       falls back to safe save and power-off
```

No user-facing sleep configuration is required initially.

### Required suspend choreography

- Confirm `/sys/power/state` supports `mem` on the target kernel.
- Save and restore ALSA state where necessary.
- Stop or quiesce radios and services that can cause `EBUSY`.
- Handle a configured Wi-Fi interface with no reachable access point.
- Use retry and backoff for transient suspend failures.
- Add a charging guard where the platform requires it.
- Debounce the synthetic or repeated power-button event after resume.
- Restore the CPU governor and cap after resume.
- Reopen audio and display resources safely.
- Power off after repeated failure rather than remaining in a hot half-suspended state.

The existing faux-sleep loop wakes periodically to evaluate power and wake conditions. It
is not a true busy spin, but its actual idle residency and power draw should be measured.
Shorten or replace it only when on-device data shows a meaningful benefit.

### Stress tests

- 100 repeated suspend/resume cycles
- Suspend while in menu and while a game is paused
- Suspend with audio active
- Suspend while charging
- Suspend with Wi-Fi configured but unavailable
- Failed suspend injection
- Resume-button bounce
- Resume followed immediately by shutdown
- Verify SRAM and state integrity after every cycle

---

## 5. Reliability and bulletproof operation

Reliability is a project pillar equal to heat and gameplay.

### Required baseline

Current MinUI commit:

- `cd5d91f8ece44c4712be2aac545dd82422d253d1`

This shutdown hardening should be treated as the minimum baseline. It includes work such as:

- Reducing nested process-tree depth with `exec`
- Cleaning up Keymon threads and handles
- Avoiding an unnecessary maximum-CPU transition during shutdown
- Stopping services
- Unmounting the SD card
- Adding a watchdog/fallback path

Also retain the upstream Brick audio mixer work merged through PR #26:

- Merge commit `4d3b12e17c404bae7e1957b08bccaf01cd4e3716`

### Additional reliability work

- Atomic SRAM and save-state writes
- Flush SRAM at safe lifecycle points
- Temporary-file plus rename for config/state updates
- Corrupt-config detection and automatic fallback
- Corrupt or incompatible save-state handling
- Core-launch timeout and recovery
- Core-crash detection and return to the menu
- Governor restoration after abnormal termination
- Audio and framebuffer cleanup after abnormal termination
- Suspend rollback when a subsystem cannot be restored
- Low-battery emergency save and power-off
- SD-card unmount validation
- Bounded watchdog behavior
- Read-only or reduced-write runtime areas where practical
- Reproducible builds with pinned dependencies and core revisions

Do not add complex recovery behavior without fault-injection tests.

---

## 6. Core build and emulator efficiency

Before replacing large subsystems, audit every Brick core for cheap performance-per-watt
wins.

### Required audit

For every core:

- Confirm the actual target architecture.
- Confirm AArch64 paths are enabled when appropriate.
- Confirm NEON is enabled and used.
- Check for accidental generic ARM builds.
- Test LTO rather than assuming it helps.
- Remove debug instrumentation from release builds.
- Record compiler, flags, source revision, and binary hash.
- Test correctness before and after each build-flag change.

### Important evidence

NextUI commit:

- `58c7869945f9e29e7d28a4d164d803aa45b1faa0`

This corrected Picodrive's AArch64 build configuration and enabled the intended optimized
path. Audit the current MinUI Picodrive build before assuming that change is still needed,
then apply the equivalent fix if required.

---

## Cross-check data: verify on device

Fork comments suggest a TG5040 frequency range with a low point around 408 MHz, a middle
point around 1200 MHz, a second-highest point around 1800 MHz, and a possible 2000 MHz
performance/overclock point. These are clues, not project constants.

> **Measured on-device (2026-07-01):** the OPP **floor is 408 MHz** (no lower step), stock cap held
> at **1800 MHz**, and the 2.0 GHz OC is never used. The clues checked out; the guidance below —
> read the device, never label a frequency stock from another fork's comments — still stands.

The implementation must inspect the actual target device:

```sh
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_frequencies
cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_min_freq
cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors
cat /sys/power/state
```

Also capture:

- Thermal-zone names and readings
- Current and maximum frequencies under sustained load
- Governor behavior under simple and demanding games
- Battery voltage/current data exposed by the PMIC or power-supply sysfs entries
- Display refresh behavior
- Audio buffer behavior

Never label a frequency "stock" or "overclocked" solely from another fork's comments.

---

## Cautions inherited from the survey

### Core and audio threading

Base MinArch already contains threading-related options or paths. Some forks disabled them
for particular cores or platforms after crashes. Before using core/render/audio affinity:

- Handle framebuffer size changes.
- Recreate buffers safely after resolution changes.
- Gate behavior per core and platform.
- Test shutdown and suspend while a worker is active.
- Avoid cancellation patterns that can leave mutexes or audio devices locked.

### Post-processing

Screen effects, overlays, and shader chains add work and are outside the project's thesis.
Stay on a plain, accurate presentation path unless a transformation is required for correct
aspect ratio, rotation, or scaling.

### Polling and monitoring

Do not add persistent high-frequency monitoring loops for temperatures, frequency, battery,
or frame timing. Reuse existing frame events, sample slowly where possible, and disable
verbose instrumentation in release builds.

---

# Recommended implementation roadmap

## Stage 0 — Baseline and measurement

- Fork the latest suitable MinUI baseline.
- Preserve the current Brick audio and shutdown fixes.
- Pin all source and core revisions.
- Add reproducible build scripts.
- Add optional structured diagnostic logging.
- Establish reference screenshots, audio captures, and save files.
- Build an on-device benchmark matrix.

**Exit criteria:** Existing supported games behave no worse than the chosen MinUI baseline.

## Stage 1 — CPU and power lifecycle

- Discover the device OPP table and governors at runtime.
- Add safe kernel-governor control.
- Connect the frame-aware controller to `scaling_max_freq` or equivalent caps.
- Add hysteresis and bounded transition behavior.
- Guarantee profile restoration on all normal and abnormal exits.
- Confirm that no code path selects an unverified overclock frequency.

**Exit criteria:** Lower sustained temperature or power draw with no regression in frame
pacing, audio, or game speed.

## Stage 2 — Core build audit

- Audit all cores for AArch64, NEON, LTO, and release flags.
- Correct Picodrive and any other misconfigured core.
- Build a per-core compatibility and performance table.

**Exit criteria:** Equal or better correctness and performance at equal or lower CPU caps.

## Stage 3 — Suspend and power reliability

- Port deep sleep from the clean stock-MinUI reference.
- Integrate retry, service quiescing, charging behavior, and resume debounce.
- Restore governor, display, audio, and input safely.
- Add safe power-off fallback.

**Exit criteria:** Pass the repeated suspend/resume and save-integrity stress suite.

## Stage 4 — Renderer modernization

- Introduce verified NEON primitives.
- Optimize rotation and region handling.
- Reduce copies.
- Add correct double buffering/page flipping.
- Add conditional threaded rendering.
- Benchmark a minimal GLES path separately.

**Exit criteria:** Better p95/p99 presentation time or lower power/temperature with identical
output and no tearing.

## Stage 5 — Audio and frame pacing

- Add instrumentation for queue depth and underruns.
- Implement nonblocking buffering and a bounded resampler behind a developer flag.
- Add a frame limiter independent of audio blocking.
- Add per-core fallbacks.
- Validate PS1 FMV, menus, gameplay, fast-forward, suspend, and resume.

**Exit criteria:** No audio crackle, runaway emulation, accumulated drift, or pacing
regression across the test matrix.

## Stage 6 — Fault tolerance

- Atomic saves and configs
- Crash recovery
- Corrupt-data fallback
- Low-battery emergency handling
- Shutdown and unmount validation
- Fault injection and soak testing

**Exit criteria:** No save corruption or unrecoverable user-facing failure in repeated test
runs.

---

# Benchmark and acceptance plan

## Systems and scenarios

At minimum test:

- NES or similarly light 60 Hz system
- SNES, including demanding enhancement-chip titles
- Game Boy Advance
- Genesis/Picodrive
- PlayStation gameplay
- PlayStation FMV and menus
- PAL content
- Rotation-heavy handheld content
- Fast-forward
- Save/resume
- Suspend/resume
- Repeated core launch and exit

Suggested demanding titles should be legally supplied by the tester and remain consistent
across revisions.

## Metrics

Capture:

- Average, p95, and p99 emulation frame time
- Average, p95, and p99 presentation time
- Missed or duplicated frames
- Audio underruns and overruns
- Emulation speed accuracy
- CPU frequency residency
- CPU utilization
- Thermal readings over time
- Battery discharge rate or power estimate
- Memory growth during a long session
- Launch time
- Suspend and resume latency
- Shutdown success
- Save and state integrity

## Thermal soak

For each candidate configuration:

1. Start from a similar battery level and ambient temperature.
2. Run the same game and scene for 30–60 minutes.
3. Record temperature, frequency residency, frame timing, audio errors, and battery data.
4. Repeat enough times to distinguish real improvement from run-to-run noise.

A lower CPU percentage is not sufficient evidence. Prefer the solution with lower total
power and temperature while preserving correct output.

## Reliability stress targets

- 100 launches/exits per representative core
- 100 suspend/resume cycles
- 100 save/resume cycles
- Repeated failed-launch simulation
- Repeated forced core termination
- Repeated shutdown while services are active
- Long-running memory test for audio and rendering paths

## Release gate

A change should not become default unless it demonstrates:

- No overclocking
- No game-speed error
- No new tearing
- No new audio artifacts
- No save corruption
- No shutdown or suspend regression
- No sustained memory growth
- Equal or lower thermals/power, or a clearly justified compatibility benefit

---

# Commit-level evidence map

| Source | Commit / PR | Why it matters |
|---|---|---|
| Current MinUI | `cd5d91f8ece44c4712be2aac545dd82422d253d1` | Shutdown hardening, process cleanup, SD unmount, watchdog behavior, avoids unnecessary maximum CPU during shutdown. |
| Current MinUI | PR #26 / `4d3b12e17c404bae7e1957b08bccaf01cd4e3716` | Brick audio mixer, mute, volume, and DAC corrections already upstream. |
| Current MinUI | PR #31, unmerged | Dynamic-resampling experiment; exposes PS1 timing risk when audio blocking is removed. Reference only. |
| Current MinUI | PR #24, unmerged | Deep-sleep implementation and measured idle-drain claim. Compare with the original zhaofengli branch. |
| NextUI | `6990d474cabf6c07d80e53140a2ce66760c3f39a` | Replaces userspace governor loop with kernel governors; important thermal architecture reference. |
| NextUI | `afb3783de5b017f0f02862a23024bb44ecc4cc75` | Changes Auto governor behavior to schedutil and adjusts caps. |
| NextUI | `e9e91137b6356ce663d5faa054476e7ce19e7b1e` | Fixes CPU remaining in Performance after startup and restores configured mode. |
| NextUI | `fd77edfa50eccce8363e6de00064366a7c982338` | Fixes resampler output memory leak. |
| NextUI | `58c7869945f9e29e7d28a4d164d803aa45b1faa0` | Corrects Picodrive AArch64/NEON build path. |
| NextUI | `c6039fc2bcfbcd66bacc93480f2964178b762eb4` | More aggressive power-off protection and PMIC handling; study carefully rather than copying blindly. |
| MyMinUI | Renderer history | NEON scaling, optimized rotation, double buffering, border skipping, lower render time, selective multicore ideas. Review the full sequence, not only the final diff. |
| zhaofengli/MinUI | `deep-sleep` branch | Clean suspend-to-RAM implementation using stock MinUI-style power APIs. |

---

# Licensing and attribution

Do not assume that code can be copied merely because it appears in a community fork.
Before incorporating code:

- Verify the license of the source repository and the specific file.
- Verify licenses for bundled cores and third-party libraries.
- Preserve required copyright and license notices.
- Record the source repository, branch, commit SHA, and material modifications.
- Avoid importing code with unclear or incompatible licensing until reviewed.

Keep a `THIRD_PARTY_NOTICES.md` or equivalent provenance file in the project.

---

# Instructions for Claude

When using this survey to plan or implement work:

1. Inspect the current project tree before assuming a referenced fix is missing.
2. Do not merge NextUI, MyMinUI, or another fork wholesale.
3. Produce small, reviewable commits grouped by subsystem.
4. Include the donor repository and commit SHA in imported-change commit messages.
5. Preserve current behavior before optimizing it.
6. Add measurements before changing CPU, rendering, or audio policy.
7. Never hardcode an unverified frequency table.
8. Never select a suspected overclock frequency.
9. Keep new controls automatic and out of the user interface.
10. Treat crashes, save corruption, audio drift, and suspend failures as release blockers.
11. Prefer total-device power and thermal measurements over CPU utilization alone.
12. Update this document when new evidence changes a recommendation.

The desired final system should feel as simple as MinUI while being substantially more
modern internally: frame-aware, efficient, tear-free, suspend-capable, and difficult to
break.
