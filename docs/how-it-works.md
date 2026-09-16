# How MinUI Zero works

The mechanisms behind the measured results. The numbers themselves, and the reasoning behind every
claim, live in [`bench/`](bench/) and [`DECISIONS.md`](DECISIONS.md).

## The governor, and why there's no CPU Speed setting

Stock MinUI and most forks use a hand-picked static clock per console: one number that has to cover
the heaviest game on the system, so it runs hot for everything else. NextUI delegates to the kernel's
utilization-based scaling, which is genuinely good at steady-state clock selection, but utilization
is target-blind. It cannot know that fast-forward wants 4x speed, or that a paused emulator is not a
struggling one.

MinUI Zero keeps the kernel's scaling for what it is good at and adds a frame-aware layer above it
that knows the target:

1. The frontend measures whether the game is holding its target frame rate.
2. When there is unused headroom, it lowers the CPU ceiling.
3. The kernel picks the most efficient clock beneath that ceiling.
4. If a demanding scene needs more, the ceiling rises again within about a second.
5. A clock that failed to hold full speed is remembered and not immediately retried.

Every system ships a clock bracket measured on real hardware, and the loop above runs wherever that
bracket has room: Bloody Roar II pays 1800 only in the scenes that need it. Six of the lightest
systems (Game Boy, GBC, NES, Master System, Game Gear, TurboGrafx-16) ship a FIXED bracket of
1008 MHz instead, because measurement found nothing useful below it; with `MINARCH_FMIN` equal to
`MINARCH_FMAX` the controller has no room to move and the cap stays flat by design. Either way the
CPU Speed setting is gone: the machine answers the question a menu used to ask, per system, and
per game wherever that still buys something.

Design notes and the closed-loop model: [`thermal-governor-design.md`](thermal-governor-design.md).
How this differs from NextUI's approach: [`nextui-comparison.md`](nextui-comparison.md).

## Optimize CPU, the self-calibrating undervolt

**TrimUI only.** Every chip is a little different, and factory voltage tables carry margin that many
individual chips do not need. Run **Tools → Optimize CPU**, leave the device on its charger, and for
about 90 minutes it measures its own silicon: stepping voltage down under load to find each clock's
real limit, then adding a safety guard. It restarts itself several times, and that is the measurement
working, since the freeze *is* the data point.

The result is **~20% less CPU power at identical clocks**, measured, with nothing to configure
afterward. Voltages apply at runtime only, so any reboot returns to factory-safe values. Back up
saves before calibrating, and revert anytime from the same tool.

Background: [`undervolt-spike-design.md`](archive/undervolt-spike-design.md) and
[`dtb-undervolt-primer.md`](dtb-undervolt-primer.md).

## Deep sleep

**TrimUI and Anbernic.** Press POWER and the device suspends to RAM instead of leaving the OS awake
behind a dark screen: state saved, audio closed, near-zero draw. It wakes almost instantly, right
where you left off. An opt-out tool is included for anyone who prefers the stock behaviour.

On the RG35XX Plus this is measured at **~1.0 %/h suspended against 8.79 %/h while playing**, roughly
nine times cheaper and about four days of standby. It also replaces the only idle behaviour that
device previously had, which was to power itself off and lose your place.

The Miyoo Mini family cannot do this at all: its vendor kernel is built without suspend support, so
`/sys/power/state` is empty and there is no suspend mode for any firmware to ask for. See the
[README](../README.md#devices) for what happens there instead.

Design notes: [`deep-sleep-design.md`](deep-sleep-design.md).

## Idle is truly idle

The launcher renders without the GPU on the TrimUI Brick, so the GPU domain suspends and the menu
runs at around 26°C. Radios and LEDs are off, no daemon polls in the background (keymon was rewritten
to block rather than spin, taking idle wakeups to zero), and idling on the charger shows a dim
battery screen before sleeping, which charges cooler and lets the charge LED finish its job.

## Presentation and frame pacing

The render path is software RGB565 rather than GL, because on this hardware keeping the GPU lit
usually costs more than it saves. Frames are paced against the panel's real measured rate rather than
an assumed 60 Hz, and identical consecutive frames are not re-sent to the display, so a static screen
lets the CPU finish early and idle.

Details: [`no-gl-present-proposal.md`](archive/no-gl-present-proposal.md),
[`audio-pacing-design.md`](archive/audio-pacing-design.md), and for the PlayStation frontend,
[`threading-v2-design.md`](threading-v2-design.md).
