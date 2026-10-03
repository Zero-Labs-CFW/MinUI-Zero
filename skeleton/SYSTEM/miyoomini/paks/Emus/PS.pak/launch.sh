#!/bin/sh

EMU_EXE=pcsx_rearmed

###############################

EMU_TAG=$(basename "$(dirname "$0")" .pak)
ROM="$1"
mkdir -p "$BIOS_PATH/$EMU_TAG"
mkdir -p "$SAVES_PATH/$EMU_TAG"
HOME="$USERDATA_PATH"
# 128MB device: PS1 is the one core we ship that will OOM without swap. needs-swap
# creates/enables the swapfile and marks /tmp/using-swap; MinUI.pak/launch.sh swapoffs
# it when the game exits, so the file is only active while it is actually needed.
#
# ABORT if it could not be enabled. Launching anyway means an OOM kill a few seconds later, which
# reads as "PS1 is broken" rather than "the card is full" — needs-swap already showed the reason.
needs-swap || exit 1
cd "$HOME"
# Closed-loop governor clock bracket (kHz). OPPs: 400/600/800/1000/1100/1200 (measured).
#
# MEASURED for this system (2026-07-28, generation-rate ground truth): THPS generates 59.5fps
# against a 59.94 target and BR2 60.25 against 60 at this bracket — PS1 RUNS AT FULL SPEED here.
export MINARCH_FMIN=1000000
export MINARCH_FMAX=1200000
# Audio ring: PS keeps its pre-2026-10-03 capacity (184ms = 12 frames sized at 44.1k in, played at 48k). Every other system moved
# to an 8-frame ring held at ~67ms; pcsx load stalls exceed that (BR2/THPS, 2026-07-08) and presentation-
# drop's 50/66% hysteresis is tuned to this ring.
export MINARCH_SND_RING_FRAMES=11  # in frame-periods so 50 Hz discs keep their old ring too (184ms at 60 Hz)

# NO overclock — and read this before "fixing" PS1 performance here at all. The full story:
#
# A telemetry artifact painted 1-in-6 frames as over-budget (p95 ~20.4ms vs the 16.7ms budget),
# which read as "needs ~1.5GHz". Six successive A/B knobs failed to move that number — including
# an MPLL overclock PIN-VERIFIED at 1488MHz for a whole bench (+24% clock, 0% change), dithering
# off, GPU/SPU threads, and CD read-ahead 1024. A number immune to EVERYTHING is not a workload;
# it was the audio-pacing wall: work_us included ring-full blocking (83% of frames block — that
# is what paces a full-speed game) and the ms-rounded pace subtraction skipped itself whenever
# rounding pushed the estimate past the raw window. Fixed in minarch (us-precision, clamped);
# generation rate is the ground truth that exposed it.
#
# BR2 chop is REAL and is a device limit, not a missing tweak. Everything obvious is refuted
# (all MMP/BR2, 4 min or 2 min runs, generation pinned at 60.00 fps in every single arm):
#   CPU clock      pin-verified 1488MHz MPLL ................ 0% change (memory-bound, not clock)
#   presentation-drop OFF ..................... 64 -> 1581 underruns (it is PROTECTING; keep it)
#   audio ring 150ms / 250ms ...... 58 / 28 underruns-per-min vs a 15.9 baseline — INCONCLUSIVE, do
#                                   not cite as a refutation: 120s sub-windows of the SAME baseline
#                                   run span 29.0 / 14.5 / 3.0, so BR2's attract-loop scene mix
#                                   dominates this metric and both arms sit inside the noise
#   tg5040's 480i minimal-prescale fix ......... does not apply (that feeds the Crisp render-target
#                                   path; MMP locks sharpness and PLAT_setSharpness is a no-op)
# CONCLUSION: the device cannot both present every frame AND keep BR2's audio ring fed. Every lever
# tried either does nothing (clock) or just chooses WHICH deficit you perceive (drop off, depth-2).
# The shipped config picks the least-bad point on that curve: occasional visible stutter, mostly
# clean audio. This is a hardware limit on a dual Cortex-A7, not a missing optimization.
#
#   threading v2 depth-2 ....... TESTED 2026-07-31 and WORSE. (It had to be compiled in first: the
#                                   makefile gates the engine to tg5040, so earlier ZERO_FTV2_DEPTH
#                                   attempts were silent no-ops.) Once engaged it removes the
#                                   stutter entirely — presentation-drop fires 0 times vs 43/13 —
#                                   but only by not protecting audio: underruns 29-50/min serial ->
#                                   117-270/min. Same trade as disabling the drop, so it relocates
#                                   the deficit rather than removing it. Reverted; tg5040-only.
#
# METHOD NOTE for whoever picks this up: underruns-per-minute on BR2 is a NOISY metric (10x spread
# across sub-windows of one run) because the attract loop shows different scenes. Only large effects
# are trustworthy on it; use equal-length runs and treat anything under ~3x as unproven.
# The MINARCH_OC_KHZ mechanism remains available (platform.c) for any pak WITH a real receipt.

# Runs at nice 0 (no `nice`), matching tg5040. See docs/DECISIONS.md D61.
# The audio shim is applied to THIS process only, never exported to the helpers above.
LD_PRELOAD="$MINARCH_PRELOAD" minarch.elf "$CORES_PATH/${EMU_EXE}_libretro.so" "$ROM" &> "$LOGS_PATH/$EMU_TAG.txt"
