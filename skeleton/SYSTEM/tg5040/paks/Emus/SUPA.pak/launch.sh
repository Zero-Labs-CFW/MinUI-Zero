#!/bin/sh

EMU_EXE=mednafen_supafaust

###############################

EMU_TAG=$(basename "$(dirname "$0")" .pak)
ROM="$1"
mkdir -p "$BIOS_PATH/$EMU_TAG"
mkdir -p "$SAVES_PATH/$EMU_TAG"
HOME="$USERDATA_PATH"
cd "$HOME"
# closed-loop governor clock bracket (kHz); see docs/thermal-governor-design.md
# Floor 600 again (D71): the governor now climbs the moment the audio ring runs low, so the ~1 s slip after a sink no
# longer underruns the ~67 ms ring. ActRaiser at 600: 3 of 9 runs underran before, 6 of 6 clean after (Brick + Pro,
# 2026-10-06). An 816 floor briefly stood in for that fix (D70); it raised every static SNES scene by one OPP.
export MINARCH_FMIN=600000
export MINARCH_FMAX=1416000
# Present-skip default-on (v1.5.2): byte-identical frames skip GLES upload/submit/swap so the
# CPU idles sooner. Static/menu scenes win (SNES ~-28% CPU on ActRaiser, 100% skip), motion is
# break-even; supafaust is MULTI-THREADED and was validated clean on both devices at pinned +
# roaming clocks. Gate is presence-only (getenv!=NULL) — remove this prefix to disable; =0 would NOT.
ZERO_DUP_SKIP=1 minarch.elf "$CORES_PATH/${EMU_EXE}_libretro.so" "$ROM" &> "$LOGS_PATH/$EMU_TAG.txt"
