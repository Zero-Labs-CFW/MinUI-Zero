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
cp "$REPO/workspace/h700/libmsettings/libmsettings.so" "$LIB/" 2>/dev/null || true
for _l in "$REPO"/skeleton/SYSTEM/h700/lib/*; do [ -f "$_l" ] && cp "$_l" "$LIB/"; done
for _b in "$REPO"/skeleton/SYSTEM/h700/bin/*; do [ -f "$_b" ] && { cp "$_b" "$BIN/"; chmod +x "$BIN/$(basename "$_b")"; }; done
[ -f "$REPO/skeleton/SYSTEM/tg5040/bin/dropbearmulti" ] && cp "$REPO/skeleton/SYSTEM/tg5040/bin/dropbearmulti" "$BIN/dropbearmulti" && chmod +x "$BIN/dropbearmulti"
cp -R "$REPO/skeleton/SYSTEM/h700/paks" "$STAGE/.system/h700/paks"
[ -f "$REPO/skeleton/SYSTEM/h700/system.cfg" ] && cp "$REPO/skeleton/SYSTEM/h700/system.cfg" "$STAGE/.system/h700/system.cfg"
cp -R "$REPO"/skeleton/EXTRAS/Tools/h700/* "$STAGE/Tools/h700/"
[ -f "$REPO/workspace/all/minput/build/h700/minput.elf" ] && cp "$REPO/workspace/all/minput/build/h700/minput.elf" "$STAGE/Tools/h700/Input.pak/" 2>/dev/null || true
DC="$REPO/workspace/tg5040/other/DinguxCommander-sdl2"
if [ -d "$STAGE/Tools/h700/Files.pak" ] && [ -f "$DC/DinguxCommander-h700" ]; then
	cp "$DC/DinguxCommander-h700" "$STAGE/Tools/h700/Files.pak/DinguxCommander"; cp -R "$DC/res" "$STAGE/Tools/h700/Files.pak/" 2>/dev/null || true
fi
# version stamp: same shape the image writes, from the git tree
V="MinUI Zero (dev-$(date +%Y%m%d))"; H=$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo unknown)
printf '%s\n%s\n' "$V" "$H" > "$STAGE/.system/version.txt"
printf 'MinUI-Zero-h700-dev-%s-%s\n' "$(date +%Y%m%d)" "$H" > "$STAGE/latest.txt"
touch "$STAGE/latest.txt"
echo "staged h700 payload: $(find "$STAGE" -type f | wc -l | tr -d ' ') files"
cd "$REPO"
PAYLOAD="$STAGE" DEVROOT=/mnt/mmc LATEST="$STAGE/latest.txt" sh tools/deploy-device.sh h700 "$TARGET" -i "$HOME/.ssh/tg5040_dev"
