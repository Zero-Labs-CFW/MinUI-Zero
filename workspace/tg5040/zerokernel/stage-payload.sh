#!/bin/sh
# Assemble the Zero kernel payload that ships at .system/tg5040/kernel/ (consumer: skeleton/SYSTEM/tg5040/bin/zerokernel.sh).
# Runs on the Mac, offline. The kernel, modules and recovery image come from the kernel build notes (Docker build,
# .notes/2026-11-14-tg5040-own-kernel/build.sh + mkimg.py); the GPU files are the DDK 1.11 userspace from the
# Sonic Pad SDK, checked against plastron's files.sha256. Large binaries stay out of git: they land in
# workspace/tg5040/zerokernel/payload/ (ignored), and payload.sha256 (tracked) pins every byte. The makefile
# refuses a payload that does not match it.
#
# Usage: sh workspace/tg5040/zerokernel/stage-payload.sh <kernel notes dir> <release id> <image name>
#   e.g. sh workspace/tg5040/zerokernel/stage-payload.sh .notes/2026-11-14-tg5040-own-kernel ship10.1 ship10
set -eu
K=$(cd "$1" && pwd); REL=$2; NAME=$3
HERE=$(cd "$(dirname "$0")" && pwd)
OUT="$HERE/payload"
IMG="$K/work/zero-recovery-$NAME.img"
MODS="$K/work/images-$NAME"
GPU="$K/fixes/gpu/blobs/lib64"
GPU_SUMS="$(cd "$K/../2026-11-10-tortos-plastron/src/plastron/buildroot/package/pvr-ge8300" && pwd)/files.sha256"
STOCK_PROCD="$K/fastinit/bin/procd"     # the Brick's stock procd, used only to check zerokernel.sh's patch data
ZK="$HERE/../../../skeleton/SYSTEM/tg5040/bin/zerokernel.sh"
STOCK_REC="$K/recon/recovery.bin"
case "$REL" in *[!A-Za-z0-9._-]*|'') echo "bad release id" >&2; exit 1 ;; esac

md5f() { md5 -q "$1" 2>/dev/null || md5sum "$1" | cut -d' ' -f1; }
sizef() { wc -c < "$1" | tr -d ' '; }

[ -f "$IMG" ] && [ "$(head -c 8 "$IMG")" = "ANDROID!" ] || { echo "no Android boot image at $IMG" >&2; exit 1; }
[ "$(sizef "$IMG")" -lt 15728640 ] || { echo "image overlaps the zlog MiB (15 MiB of recovery)" >&2; exit 1; }
(cd "$GPU/.." && shasum -a 256 -c "$GPU_SUMS" >/dev/null) || { echo "GPU blob checksum mismatch" >&2; exit 1; }
# procd is never shipped (Dan, 2026-11-19): zerokernel.sh patches the device's own /sbin/procd at install time.
# Check its plain patch data here against the stock procd: the input md5, then the result md5 and zinit's size gate.
PD_IN=$(sed -n 's/^\([0-9a-f]\{32\}\)|\([0-9a-f]\{32\}\)$/\1/p' "$ZK"); PD_OUT=$(sed -n 's/^\([0-9a-f]\{32\}\)|\([0-9a-f]\{32\}\)$/\2/p' "$ZK")
[ "$(md5f "$STOCK_PROCD")" = "$PD_IN" ] || { echo "stock procd is not the md5 zerokernel.sh patches" >&2; exit 1; }
PT=$(mktemp); cp "$STOCK_PROCD" "$PT"
sed -n "/^ZK_PROCD_PATCH='/,/^'/p" "$ZK" | grep '|' | while IFS='|' read -r o b; do
	printf "$b" | dd of="$PT" bs=1 seek="$o" conv=notrunc 2>/dev/null; done
[ "$(md5f "$PT")" = "$PD_OUT" ] && [ "$(sizef "$PT")" = 353800 ] || { rm -f "$PT"; echo "zerokernel.sh's procd patch does not give $PD_OUT" >&2; exit 1; }
rm -f "$PT"
[ "$(md5f "$STOCK_REC")" = 78f6f12ee2772c57527b38a71599e58a ] || { echo "stock recovery dump changed" >&2; exit 1; }

rm -rf "$OUT"; mkdir -p "$OUT/root/lib/modules/4.9.191-zero" "$OUT/root/etc/rc.d" "$OUT/root/usr/lib/zero/rc" \
	"$OUT/root/usr/lib/zero/modules.d" "$OUT/root/usr/lib/zero/gpu/lib" "$OUT/root/usr/lib/zero/gpu/firmware"
cp "$IMG" "$OUT/zero-recovery.img"
dd if="$STOCK_REC" of="$OUT/recovery-stock-head.bin" bs=512 count=1 2>/dev/null
cp "$MODS"/*.ko "$OUT/root/lib/modules/4.9.191-zero/"   # every module the build made, as on the dev Brick (stage/2-install.sh)
cp "$HERE/zero-xr829" "$OUT/root/usr/lib/zero/modules.d/zero-xr829"
for f in libEGL.so libGLESv2.so libGLES_CM.so libIMGegl.so libsrv_um.so libglslcompiler.so libusc.so libpvrNULL_WSEGL.so; do
	cp "$GPU/$f" "$OUT/root/usr/lib/zero/gpu/lib/$f"
done
cp "$GPU/firmware/rgx.fw.22.102.54.38" "$OUT/root/usr/lib/zero/gpu/firmware/"
# the only Zero files in rc.d: one stub under each name, the real scripts beside the rest of Zero
for f in S01zero K01zero; do cp "$HERE/rc-stub" "$OUT/root/etc/rc.d/$f"; cp "$HERE/$f" "$OUT/root/usr/lib/zero/rc/$f"; done
echo "$REL" > "$OUT/root/usr/lib/zero/VERSION"
echo "$REL" > "$OUT/VERSION"

# manifest.md5: "<md5>  <overlay path>", VERSION last (zerokernel.sh swaps in this order)
( cd "$OUT/root" && find . -type f ! -path ./usr/lib/zero/VERSION | sort | while read -r p; do
	echo "$(md5f "$p")  ${p#.}"; done
  echo "$(md5f ./usr/lib/zero/VERSION)  /usr/lib/zero/VERSION" ) > "$OUT/manifest.md5"

# known-images.txt: "<bytes> <md5> <id>", every image Zero or a dev device ever put in recovery (dev installs:
# .notes/2026-11-18-own-kernel-ship/b0/install-*.txt, Brick ship3/5/8, Brick Pro ship3/6/8, Smart Pro ship3 to ship10),
# so an update or undo knows them as ours; the shipped one LAST. Its id is the image name, not the release: the env
# and the stop rules key on it (zero_k_img, zero_k_bad), so a release that keeps the same kernel bytes keeps the id
# and a device stopped on that image stays stopped, and a pending fail count still counts.
{
	for old in trim8 ship1 ship2 ship3 ship4 ship5 ship6 ship6d ship7 ship7d ship8 ship9 ship10; do
		f="$K/work/zero-recovery-$old.img"; [ "$old" = "$NAME" ] && continue
		[ -f "$f" ] && echo "$(sizef "$f") $(md5f "$f") dev-$old-$(md5f "$f" | cut -c1-8)"
	done
	echo "$(sizef "$IMG") $(md5f "$IMG") $NAME-$(md5f "$IMG" | cut -c1-8)"
} > "$OUT/known-images.txt"

( cd "$OUT" && find . -type f | sort | sed 's|^\./||' | while read -r p; do echo "$(shasum -a 256 "$p" | cut -d' ' -f1)  $p"; done ) > "$HERE/payload.sha256"
# the procd table checked above, pinned for the makefile's source check (check-payload-sources.sh), then that check
sh "$HERE/check-payload-sources.sh" --write-pins
sh "$HERE/check-payload-sources.sh"
echo "staged $(find "$OUT" -type f | wc -l | tr -d ' ') files, $(du -sk "$OUT" | cut -f1) KB, image $(md5f "$IMG")"
