#!/bin/sh
# h700 GB pak. Standard MinUI boilerplate: the launcher entry point
# (paks/MinUI.pak/launch.sh, or the OS-side minui-frontend.sh on our image) exports every path,
# PATH, LD_LIBRARY_PATH, the measured panel rate and the ALSA driver, so a pak only names its core.
# Normalized 2026-08-26 from bespoke per-pak scripts that re-exported all of it 15 times over.

EMU_EXE=gambatte

###############################

EMU_TAG=$(basename "$(dirname "$0")" .pak)
ROM="$1"
mkdir -p "$BIOS_PATH/$EMU_TAG"
mkdir -p "$SAVES_PATH/$EMU_TAG"
HOME="$USERDATA_PATH"
cd "$HOME"
# Clock bracket (kHz), h700 only (earned per-SoC divergence, 2026-10-03). The h700 governor cannot use
# the predictive sink gate (frame work reads ~16.7ms at every clock on this present path), so it probes
# down until generation breaks: 936 holds 60 for minutes, the next step (720) collapses gambatte to ~48 fps
# = a dropout burst (Zelda DX, 2026-10-02/03). Floor at 936 so that probe never happens; 1008-1512 = 0
# underruns measured, 936 adopted from the same logs. Env-overridable for a bench A/B.
export MINARCH_FMIN="${MINARCH_FMIN:-936000}"
export MINARCH_FMAX="${MINARCH_FMAX:-1512000}"
minarch.elf "$CORES_PATH/${EMU_EXE}_libretro.so" "$ROM" > "$LOGS_PATH/$EMU_TAG.txt" 2>&1
