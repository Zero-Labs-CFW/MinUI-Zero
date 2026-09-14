#!/bin/sh

EMU_EXE=mednafen_pce_fast
CORES_PATH=$(dirname "$0")

###############################

EMU_TAG=$(basename "$(dirname "$0")" .pak)
ROM="$1"
mkdir -p "$BIOS_PATH/$EMU_TAG"
mkdir -p "$SAVES_PATH/$EMU_TAG"
HOME="$USERDATA_PATH"
cd "$HOME"
# closed-loop governor clock bracket (kHz); see docs/thermal-governor-design.md
# 600-1008 bracket (was a fixed 1008 pin). The pin came from D61 (2026-07-18): on the SERIAL
# present path a low ceiling starved short GLES upload bursts (Pokemon Gold 55-58 fps at 600/816
# caps). Threaded present (threading v2) took that burst off the frame-critical path, and the 16-bit
# systems already hold 60 at 600 on the same present path (2026-09-14 receipts: GBA 600 MHz in 94%
# of samples, under/s 0.00; MD 600 in 60%). The floor/ceiling are overridable from the environment
# so a bench harness can A/B the old pin (MINARCH_FMIN=1008000) against this bracket without
# editing the pak; a normal launch sets neither, so users get the bracket.
export MINARCH_FMIN="${MINARCH_FMIN:-600000}"
export MINARCH_FMAX="${MINARCH_FMAX:-1008000}"
# NOTE: no ring override here — mednafen_pce_fast also runs PCE-CD/CHD content whose
# sector reads can stall production far longer than a HuCard fsync; 100ms needs
# separate CD-content device receipts before it ships (Codex review finding 4)
minarch.elf "$CORES_PATH/${EMU_EXE}_libretro.so" "$ROM" &> "$LOGS_PATH/$EMU_TAG.txt"
