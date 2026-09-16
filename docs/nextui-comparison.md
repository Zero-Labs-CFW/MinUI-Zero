# NextUI Comparison

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

Source lines count each firmware's own `.c`/`.h` and exclude the emulator cores both ship; download
sizes are each project's base release zip. Code flows both ways between these projects: deep sleep
shares a lineage, and NextUI is credited in this codebase.

---

## Measured head-to-head (2026-09-14)

Earlier versions of this document compared the two governors by reading NextUI's `governor.sh`
without flashing it. This section replaces that with a direct 1:1: **one TrimUI Brick, both
firmwares on their own cards, the same seven attract-demo ROMs, radios off, brightness lowest, the
same logger on each, and all three of NextUI's CPU modes tested.** Zero v1.7.x as shipped; NextUI
6.14.0 as shipped. Frame timing came from an `LD_PRELOAD` shim hooking each firmware's present call,
plus Zero's own loop telemetry. Full report and raw data: `.notes/2026-09-13-nextui-1to1-result/`.

**Frame-hold** (fps · frames that missed their slot per minute):

| Game | Zero | NextUI auto (default) | NextUI performance | NextUI powersave |
|---|---|---|---|---|
| Bloody Roar II (PS1) | **60.2 · 1.3** | 56.1 · 232 | 60.2 · 1.1 | 55.8 · 40 |
| Tony Hawk 2 (PS1) | **60.2 · 0.0** | 60.2 · 10.5 | 60.2 · 0.9 | 60.1 · 9.0 |
| Gradius (NES) | 60.3 · 0.0 | 60.1 · 6.7 | 60.2 · 2.6 | 60.2 · 1.4 |
| Zelda DX (GBC) | 60.3 · 0.0 | 60.2 · 1.1 | 60.2 · 0.1 | 60.1 · 3.5 |
| SF2 (SNES) | 60.3 · 0.0 | 60.1 · 4.7 | 60.1 · 2.3 | 60.2 · 0.6 |
| Sonic (Genesis) | 60.3 · 0.0 | 60.2 · 0.4 | 60.2 · 0.5 | 60.1 · 3.0 |
| Mario Kart (GBA) | 60.2 · 0.0 | 60.2 · 2.5 | 60.2 · 0.5 | 60.2 · 3.1 |

Zero holds a clean 60 on every game. NextUI's **default** drops Bloody Roar to 56fps and stutters
the other PS1 title; it only holds every game cleanly in **performance** mode (2000 MHz pinned), and
its **powersave** mode (the one the NextUI author benchmarked Zero against) hitches on light systems
and still drops Bloody Roar.

**Clock for the same 60fps** (steady-state mean, MHz):

| | Zero | NextUI auto | NextUI performance | NextUI powersave |
|---|---|---|---|---|
| Bloody Roar II | 1570 | 1760 | 2000 | 902 |
| Tony Hawk 2 | 1461 | 1748 | 2000 | 833 |
| Gradius | 1003 | 1764 | 2000 | 1200 |
| Zelda DX | 1001 | 1693 | 2000 | 628 |
| SF2 | 661 | 1778 | 2000 | 1200 |
| Sonic | 763 | 1749 | 2000 | 1064 |
| Mario Kart | 617 | 1711 | 2000 | 648 |

NextUI's `auto` rides its 1800 cap on everything, including a Game Boy game; Zero's frame-aware loop
sits where the frame budget allows. Same 60fps, **41–64% less clock on the light systems**.

**Heat, battery, idle, boot, launch:**

| | Zero | NextUI auto |
|---|---|---|
| In-game CPU temperature | 33–39 °C | 30–38 °C (wash; only NextUI *performance* is hot, 41–48 °C) |
| Battery, matched 90-min drain from full | 9.9 %/hr · 119 mV/hr | 10.6 %/hr · 136 mV/hr (Zero ~7–14% less) |
| Menu idle | 597 MHz · 28.2 °C | 1522 MHz · 33.8 °C |
| Boot to menu process | 7.8 s | 9.4 s |
| Launch to first game frame | 0.9–1.3 s | 2.1–2.6 s |
| CPU modes the user must pick | none | 3 |

**The honest shape of it.** Zero runs much **cooler than stock MinUI** (2–5 °C, see the A/B below)
and much **cooler than NextUI at the menu** (28.2 vs 33.8 °C, a third of the clock, GPU powered
down). Where it does *not* pull ahead is in-game temperature against NextUI's *default*: there it is
a **wash**, because both run schedutil-family governors and, during GLES gameplay, the CPU rail is a
small share of total power (panel, GPU, DDR dominate). For the same reason battery is a **modest
~10% edge** over a matched drain, not a multiple. So Zero's decisive, uncontested wins are **quality
at stock** (holds 60 where NextUI's default drops frames, clean pacing, ~2× faster launch),
**cooler and near-zero-draw at idle** (deep sleep at 2 min vs NextUI's 10-min suspend), and **no
modes to choose**. The one claim to avoid is "cooler *in games* than NextUI's default" — that
specific comparison is a tie.

---

## Background: the 2026-06 governor analysis (inferred from `governor.sh`)

The material below predates the head-to-head above. It was researched 2026-06-30 from the `nextui`
remote (release notes, PR #695, their shipped `governor.sh`) **without flashing NextUI**, so its
NextUI temperatures are inferred, not measured. Two of its conclusions have since been overturned by
the direct test and are corrected inline. Kept for the governor-design history and the PR #695
context, both still valid.

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
| Cap | 1800 global (every system) | **per-system** (PS1 1800, 16-bit 1416, 8-bit 600–1008 bracket) |
| 2.0GHz OC | exposed in Performance mode | **never** (thesis: no overclock) |
| Frame-aware loop | none | built; the 2026-09 head-to-head showed it holds 60 where NextUI's schedutil default drops PS1 frames |
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
- **vs NextUI:** this inferred "thermal tie" was **half right**, and the 2026-09 head-to-head above
  settled it. *In games* the temperatures are a wash, as predicted (both schedutil-family). *At idle*
  they are not: Zero's GPU-dark menu idles 5.6°C cooler at a third of the clock, because NextUI's menu
  is a live GL scene. And the frame-hold that a temperature tie hides is the real story: Zero holds 60
  at stock where NextUI's default drops PS1 frames. Our differences are per-system caps (they cap
  everything at 1800), never exposing the 2.0 OC, no modes to pick, and staying pure-software RGB565.

## The two findings that matter
1. **Independent convergence = strong validation.** Two forks, arrived separately at the identical
   core: *schedutil + range-limit, floor 408, cap one step below the 2.0 OC.* We're on the right road.
2. **Both, as it turned out.** This note originally guessed the closed-loop controller added nothing
   over plain schedutil and framed it as an either/or with per-system caps. The 2026-09 head-to-head
   overturned that: plain schedutil (NextUI's default) drops Bloody Roar to 56fps, while Zero's loop
   holds 60 at a *lower* clock (1570 vs 1760), and Zero holds 60 on every light system at 41–64% less
   clock. So per-system caps and the frame-aware loop are not competing options — together they are
   what lets one configuration replace NextUI's three manual modes, each of which compromises
   something (default drops PS1 frames, powersave hitches, performance cooks). Per-system caps are
   still the cheapest, clearest edge; the loop is what makes them safe to run low.

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
