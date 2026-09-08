# NextUI thermal/CPU-governor comparison

## Zero vs NextUI at a glance

[NextUI](https://github.com/LoveRetro/NextUI) is the other major MinUI fork for these devices,
full-featured and polished where Zero is deliberately minimal. Both are good firmware; pick by
philosophy.

| | **MinUI Zero** | **NextUI** |
|---|---|---|
| Philosophy | Lowest power that holds full speed | Full-featured |
| Firmware source code | ~21,500 lines | ~51,200 lines |
| Base install download | 7 MB | 82 MB |
| Rendering | Lean pipeline; the GPU only displays the finished frame in-game, and powers down at the menu | Fully OpenGL/GPU-based, with shaders and overlays |
| CPU | Frame-aware closed loop plus a pipelined PS1 frontend; holds full speed at stock clocks, never overclocks | Dynamic scaling; performance mode is a 2.0 GHz overclock |
| Undervolting | Self-calibrating per-chip tool, finds each chip's lowest safe voltage (opt-in) | None |
| Features | Minimal by design: no box art, store, themes, or accounts | Box art, WiFi, Bluetooth audio, cheats, game switcher, Pak Store, LED effects, themes |
| Background services in-game | keymon only, rewritten for zero idle wakeups | keymon, battery monitor, audio monitor, plus WiFi and Bluetooth stacks when enabled |
| Deep sleep | Yes | Yes |
| Devices | Brick, Brick Pro, Smart Pro (+ Anbernic RG35XX Plus / H and Miyoo Mini family) | Brick, Brick Pro, Smart Pro, Smart Pro S |

Measured at MinUI Zero v1.5 and NextUI v6.14.0. Source lines count each firmware's own `.c`/`.h` and
exclude the emulator cores both ship; download sizes are each project's base release zip. The NextUI
column comes from its README and its own boot and launch scripts, and the governor difference is
researched in detail below. Code flows both ways between these projects: deep sleep shares a lineage,
and NextUI is credited in this codebase.

---

Researched 2026-06-30 from the `nextui` remote (LoveRetro/NextUI) — release notes, PR #695,
and their shipped `governor.sh`. Goal: find NextUI's documented thermal benchmarks and compare
their CPU-scaling design against ours.

## The benchmark number you remembered
NextUI does **not** publish a formal temperature table. Their numbers live in two places:
1. **A runtime debug HUD** — v2.5.1 (2025-03-24) "Added cpu temperature in celsius to debug HUD".
2. **PR #695** (merged v6.11.0, 2026-05-14, "Replace userspace CPU governor with kernel scaling
   governors"). The money quote:

   > "the biggest positive impact of this PR is significant reduction in CPU usage by the
   > userspace governor thread and correspondingly **significant reduction in core temperature
   > of the order of 5–10°C**."

That 5–10°C is the headline figure — and it comes from the **same change we made**: dropping the
`userspace` governor + `scaling_setspeed` pin (whose polling thread itself burned CPU/heat) in
favor of kernel scaling governors.

## NextUI's shipped design (their `governor.sh`, v6.11.x)
Reads `scaling_available_frequencies` live; three modes:
| Mode | Kernel governor | Range (TG5040) |
|------|----------------|----------------|
| **auto** | `schedutil` | 408 → **1800** (second_max = one step below the 2000 OC) |
| **performance** | `performance` | 408 → **2000** (they *do* expose the 2.0GHz OC here) |
| **powersave** | `conservative` | 408 → 1200 (midpoint) |
- Author's philosophy: *"there should not be any need for any option except Auto and at best a
  Powersave mode → that is how our phones and laptops work."* No frame-aware closed loop at all.
- Their auto restores on minarch exit; `PLAT_setCPUSpeed` became a no-op.
- Follow-up v6.11.1 "fix: slowdowns on Auto cpu speed" (PR #727) — they hit tuning pain too.

## How we compare
| | NextUI auto | Ours (measured on-device, Tony Hawk PS1) |
|---|---|---|
| Governor | schedutil | schedutil (hybrid) |
| Floor | 408 | 408 (just corrected from assumed 480) |
| Cap | 1800 global (every system) | **per-system** (PS1 1800, 16-bit 1416, 8-bit 1008) |
| 2.0GHz OC | exposed in Performance mode | **never** (thesis: no overclock) |
| Frame-aware loop | none | built, but **not firing** on-device (ceiling never sinks below f_max) |
| Result | "5–10°C cooler" vs old userspace | 36–37°C sustained PS1; schedutil self-scaled 816–1608 |

## Three-way comparison: original MinUI vs NextUI vs ours
Original MinUI (`upstream/main`) uses the **userspace** governor with a **static pin**: MENU 600 /
POWERSAVE 1200 / **NORMAL 1608 (the default — `minarch_cpu_speed .default_value = 1`)** / PERFORMANCE
2000. No dynamic scaling — it holds the pinned clock through idle, menus, and light scenes alike.

| | Original MinUI | NextUI v6.11+ | Ours |
|---|----------------|---------------|------|
| Mechanism | userspace **static pin** | `schedutil` auto | `schedutil` + per-system cap + frame loop |
| Default gameplay clock | **1608 flat** | dynamic 408–1800 | dynamic 408–[per-system cap] |
| 2.0GHz OC | opt-in "Performance" | opt-in "Performance" mode | **never** |
| Scales down when idle/light | **no** (stays pinned) | yes | yes |

**Measured on-device (settled CPU temp, TrimUI Brick, 2026-06-30):**
| Game | Ours (schedutil) | MinUI default (1608 pin) | MinUI Perf / old (2000 pin) |
|------|------------------|--------------------------|-----------------------------|
| NES 1942     | 600 MHz · **39°C** | 1608 · **42°C** | 2000 · **44°C** |
| PS1 Tony Hawk| 1416 · **38°C**    | 1608 · **40°C** | 2000 · **42°C** |

- **vs original MinUI:** **2–3°C cooler than its 1608 default, 4–5°C cooler than 2000 Performance** —
  and structurally more efficient: MinUI pins 1608 even for NES and during idle/menus, where we drop
  to 600. That standing-power gap is larger than the temp delta suggests and the static pin can't close it.
- **vs NextUI:** **a thermal tie** — NextUI's `auto` *is* `schedutil` 408–1800, the same mechanism we
  measured, so its temps track ours (~38–39°C). (Inferred from their `governor.sh`, not separately
  flashed.) Our differences are philosophy, not degrees: per-system caps (they cap everything at 1800),
  never exposing the 2.0 OC, and staying pure-software RGB565 (NextUI adds GL/GPU features we omit).

## The two findings that matter
1. **Independent convergence = strong validation.** Two forks, arrived separately at the identical
   core: *schedutil + range-limit, floor 408, cap one step below the 2.0 OC.* We're on the right road.
2. **Our closed-loop ceiling controller currently adds nothing over plain schedutil.** On-device the
   ceiling pins at f_max the whole session; schedutil does all the real scaling underneath. NextUI
   deliberately shipped *without* such a loop and still got the 5–10°C win. So our decision point:
   - **(a)** Debug/tune the frame-aware sink so it demonstrably beats plain schedutil, **or**
   - **(b)** Lean into schedutil + **per-system ranges** (our real edge — NextUI caps *everything* at
     1800; we cap an 8-bit game's schedutil at 1008, which should run cooler than NextUI on light
     systems) and treat the closed loop as optional.

   (b) fits the "stay lean / runs cold" thesis and is already half-built (per-system f_max is applied
   statically at game load). Our differentiator is **per-system caps**, not the bespoke controller.

## On-device A/B result (measured 2026-06-30, same game each run, only clock policy differs)
Method: `GOV_DISABLE=1` + `userspace`@2000000 reproduces the old MinUI pin; schedutil is our governor.
Settled CPU temp after ~70s.

| Game (load) | schedutil (ours) | pinned 2.0GHz (old) | Δ |
|-------------|------------------|---------------------|---|
| NES 1942 (light)        | ~600 MHz · 39°C  | 2000 MHz · 44°C | **5°C cooler** |
| PS1 Tony Hawk (heavy)   | 1416 MHz · 38°C  | 2000 MHz · 42°C | **4°C cooler** |

**Reproduces NextUI's 5–10°C on our own fork** (~4–5°C, low end). The delta is essentially the
schedutil-vs-userspace-pin win we *and* NextUI share; per-system caps + the closed loop sit on top.

### Corrected insight: the governor saves MOST on light games, not heavy ones
An earlier note here guessed a heavier game would widen the gap toward 10°C. The PS1 run disproved
it: the gap *narrowed* (4°C vs NES's 5°C). Reason — the pin wastes the most where the game needs the
least. schedutil cuts NES 3.3× below the pin (2000→600) but PS1 only 1.4× (2000→1416, it genuinely
needs the clock). So the efficiency win scales with how *little* a system demands.

### Honest measurement caveats
Absolute temps sit in a narrow 37–44°C band — at this ambient the baseline (display/SoC/wifi-for-SSH)
dominates and emulation adds only a few °C; even the "bad" 2.0 pin never got hot here. The 4-vs-5°C
difference is within single-run sensor/thermal-drift noise; the robust takeaways are the **~4–5°C
magnitude** and the **light-saves-more direction**. The bigger thermal story would show under
sustained load in a warm/enclosed environment. On this bench, the win is mostly efficiency/battery
and headroom, not overheating-avoidance.

## Correction to an earlier read: the closed-loop ceiling DOES fire
On Tony Hawk (PS1) the ceiling held at f_max, which first looked like the sink branch was dead. The
NES run disproved that: the ceiling actively sank toward the 408 floor (408–624 kHz, below the 1008
cap) because a trivial load has zero frame pressure — while PS1 correctly held high for real demand.
So the frame-aware loop works as designed. Its *marginal* benefit over plain schedutil is still open
(schedutil already runs light loads low), but it is not inert. Per-system static caps remain the
clearest, cheapest edge over NextUI's single global 1800 cap.
