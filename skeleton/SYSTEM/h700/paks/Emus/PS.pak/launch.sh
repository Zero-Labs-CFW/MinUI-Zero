#!/bin/sh
# h700 PS pak. Standard MinUI boilerplate: the launcher entry point
# (paks/MinUI.pak/launch.sh, or the OS-side minui-frontend.sh on our image) exports every path,
# PATH, LD_LIBRARY_PATH, the measured panel rate and the ALSA driver, so a pak only names its core.
# Normalized 2026-08-26 from bespoke per-pak scripts that re-exported all of it 15 times over.

EMU_EXE=pcsx_rearmed

###############################

EMU_TAG=$(basename "$(dirname "$0")" .pak)
ROM="$1"
mkdir -p "$BIOS_PATH/$EMU_TAG"
mkdir -p "$SAVES_PATH/$EMU_TAG"
HOME="$USERDATA_PATH"
cd "$HOME"
# Audio ring: PS keeps its pre-2026-10-03 capacity (184ms = 12 frames sized at 44.1k in, played at
# 48k). Every other system moved to an 8-frame ring held at ~67ms; pcsx load stalls exceed that
# (BR2/THPS, 2026-07-08) and presentation-drop's 50/66% hysteresis is tuned to this ring.
export MINARCH_SND_RING_FRAMES=11  # in frame-periods so 50 Hz discs keep their old ring too (184ms at 60 Hz)
minarch.elf "$CORES_PATH/${EMU_EXE}_libretro.so" "$ROM" > "$LOGS_PATH/$EMU_TAG.txt" 2>&1
