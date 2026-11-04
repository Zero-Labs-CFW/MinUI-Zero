#!/bin/sh
# Whole-payload dev deploy for the h700 (Anbernic RG35XX Plus/H), the same md5-sync guarantee the Brick
# and Miyoo get from tools/deploy-device.sh. The h700 has no zip payload (it ships as a flashed image),
# so this stages the SAME tree tools/build-h700-stripped.sh bakes into the image, from the same sources,
# then hands it to deploy-device.sh with the card mount (/mnt/mmc) overridden. Cores are NOT staged
# (20+ MB, unchanged by frontend work); extra files on the device are never deleted without --delete.
#
#   make h700-build && sh tools/deploy-h700.sh root@<ip>
set -e
TARGET=${1:-root@192.168.1.59}
REPO=$(cd "$(dirname "$0")/.." && pwd)
STAGE="$REPO/build/h700-payload"
BIN="$STAGE/.system/h700/bin"; LIB="$STAGE/.system/h700/lib"
[ -f "$REPO/workspace/all/minui/build/h700/minui.elf" ] || { echo "ERROR: run 'make h700-build' first"; exit 1; }
rm -rf "$STAGE"; mkdir -p "$BIN" "$LIB" "$STAGE/Tools/h700"
for _h in minui minarch confirm say settings clock status; do
	cp "$REPO/workspace/all/$_h/build/h700/$_h.elf" "$BIN/" || { echo "ERROR: $_h.elf missing for h700"; exit 1; }
done
cp "$REPO/workspace/h700/tools/build/nightlayer" "$BIN/" || { echo "ERROR: nightlayer missing for h700"; exit 1; }
cp "$REPO/workspace/h700/tools/build/bootclock" "$BIN/" || { echo "ERROR: bootclock missing for h700"; exit 1; }
cp "$REPO/workspace/h700/libmsettings/libmsettings.so" "$LIB/" 2>/dev/null || true
for _l in "$REPO"/skeleton/SYSTEM/h700/lib/*; do [ -f "$_l" ] && cp "$_l" "$LIB/"; done
for _b in "$REPO"/skeleton/SYSTEM/h700/bin/*; do [ -f "$_b" ] && { cp "$_b" "$BIN/"; chmod +x "$BIN/$(basename "$_b")"; }; done
[ -f "$REPO/skeleton/SYSTEM/tg5040/bin/dropbearmulti" ] && cp "$REPO/skeleton/SYSTEM/tg5040/bin/dropbearmulti" "$BIN/dropbearmulti" && chmod +x "$BIN/dropbearmulti"
cp -R "$REPO/skeleton/SYSTEM/h700/paks" "$STAGE/.system/h700/paks"
cp "$REPO/workspace/h700/boards.txt" "$STAGE/.system/h700/boards.txt"   # the board table the device scripts read
# the card copy of the frontend, which the rootfs copy hands off to (MinUI.zip updates, 2026-11-04): a frontend change
# deploys like any other card file and runs from the next boot
cp "$REPO/tools/h700-strip/minui-frontend.sh" "$BIN/minui-frontend.sh"
# .system/res: the shared root (zero-log.sh, the sprite sheets, the font), as the image ships it
mkdir -p "$STAGE/.system/res" && cp "$REPO"/skeleton/SYSTEM/res/* "$STAGE/.system/res/"
[ -f "$REPO/skeleton/SYSTEM/h700/system.cfg" ] && cp "$REPO/skeleton/SYSTEM/h700/system.cfg" "$STAGE/.system/h700/system.cfg"
cp -R "$REPO"/skeleton/EXTRAS/Tools/h700/* "$STAGE/Tools/h700/"
[ -f "$REPO/workspace/all/minput/build/h700/minput.elf" ] && cp "$REPO/workspace/all/minput/build/h700/minput.elf" "$STAGE/Tools/h700/Input.pak/" 2>/dev/null || true
DC="$REPO/workspace/tg5040/other/DinguxCommander-sdl2"
if [ -d "$STAGE/Tools/h700/Files.pak" ] && [ -f "$DC/DinguxCommander-h700" ]; then
	cp "$DC/DinguxCommander-h700" "$STAGE/Tools/h700/Files.pak/DinguxCommander"; cp -R "$DC/res" "$STAGE/Tools/h700/Files.pak/" 2>/dev/null || true
fi
# File Transfer: tg5040's aarch64 busybox ftpd + dufs (same binaries the image ships; see build-h700-stripped.sh)
FT="$STAGE/Tools/h700/File Transfer.pak"
if [ -d "$FT" ]; then
	sh "$REPO/tools/h700-check-ft-bins.sh" "$REPO" || exit 1 # the pins, not just presence (Codex review 2026-10-09)
	for _f in busybox dufs; do
		cp "$REPO/workspace/tg5040/other/$_f/$_f" "$FT/" || { echo "ERROR: workspace/tg5040/other/$_f/$_f missing; run 'make tg5040-frontend' (its early target builds it)"; exit 1; }
	done
fi
# version stamp: same shape the image writes, from the git tree
V="MinUI Zero (dev-$(date +%Y%m%d))"; H=$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo unknown)
printf '%s\n%s\n' "$V" "$H" > "$STAGE/.system/version.txt"
printf 'MinUI-Zero-h700-dev-%s-%s\n' "$(date +%Y%m%d)" "$H" > "$STAGE/latest.txt"
touch "$STAGE/latest.txt"
echo "staged h700 payload: $(find "$STAGE" -type f | wc -l | tr -d ' ') files"
cd "$REPO"
PAYLOAD="$STAGE" DEVROOT=/mnt/mmc LATEST="$STAGE/latest.txt" sh tools/deploy-device.sh h700 "$TARGET" -i "$HOME/.ssh/tg5040_dev"
# The rootfs side (/opt/minui-zero: the built-in frontend and its card hand-off, the updater, the model picker,
# expand-roms) is baked into the image and is NOT part of this payload (the card copy of the frontend above is). Say so when the device's copy differs from the tree, so a fix there is never believed
# deployed (Codex review 2026-10-30). Read-only; a file the device lacks (no picker on a per-board image) is skipped.
for _f in minui-frontend.sh card-update.sh card-fsck.sh boardpick.sh boardpick.elf expand-roms.sh; do
	case "$_f" in *.elf) _src="$REPO/workspace/h700/boardpick/build/h700/$_f" ;; *) _src="$REPO/tools/h700-strip/$_f" ;; esac
	[ -f "$_src" ] || continue
	_want=$(md5 -q "$_src" 2>/dev/null || md5sum "$_src" | cut -d" " -f1)
	_have=$(ssh -i "$HOME/.ssh/tg5040_dev" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 \
		"$TARGET" "md5sum /opt/minui-zero/$_f 2>/dev/null | cut -d\" \" -f1" 2>/dev/null || true)
	[ -z "$_have" ] || [ "$_want" = "$_have" ] || \
		echo "WARNING: /opt/minui-zero/$_f on the device is not this tree's copy. This deploy does not touch the rootfs: reflash an image to test it."
done
