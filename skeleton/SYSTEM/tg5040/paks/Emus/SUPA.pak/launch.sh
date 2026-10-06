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
# Floor 816, not 600 (D70, 2026-10-06, Brick + Brick Pro, ActRaiser attract demo, WiFi off): the governor sinks to the
# floor through static scenes, and when motion resumes it needs ~1 s to climb. At 600 that deficit underran the ~67 ms
# audio ring in 3 of 9 runs (1-4 underruns each); at 816 the slip is shallower and 4 of 4 runs had none. The old
# near-full ring hid it. TrimUI receipt only: other platforms keep their own measured brackets.
export MINARCH_FMIN=816000
export MINARCH_FMAX=1416000
# Present-skip default-on (v1.5.2): byte-identical frames skip GLES upload/submit/swap so the
# CPU idles sooner. Static/menu scenes win (SNES ~-28% CPU on ActRaiser, 100% skip), motion is
# break-even; supafaust is MULTI-THREADED and was validated clean on both devices at pinned +
# roaming clocks. Gate is presence-only (getenv!=NULL) — remove this prefix to disable; =0 would NOT.
ZERO_DUP_SKIP=1 minarch.elf "$CORES_PATH/${EMU_EXE}_libretro.so" "$ROM" &> "$LOGS_PATH/$EMU_TAG.txt"
