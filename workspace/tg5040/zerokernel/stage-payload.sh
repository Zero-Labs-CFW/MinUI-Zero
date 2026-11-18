#!/bin/sh
# Assemble the Zero kernel payload that ships at .system/tg5040/kernel/ (consumer: skeleton/SYSTEM/tg5040/bin/zerokernel.sh).
# Runs on the Mac, offline. The kernel, modules and recovery image come from the kernel build notes (Docker build,
# .notes/2026-11-14-tg5040-own-kernel/build.sh + mkimg.py); the GPU files are the DDK 1.11 userspace from the
# Sonic Pad SDK, checked against plastron's files.sha256. Large binaries stay out of git: they land in
# workspace/tg5040/zerokernel/payload/ (ignored), and payload.sha256 (tracked) pins every byte. The makefile
# refuses a payload that does not match it.
#
# Usage: sh workspace/tg5040/zerokernel/stage-payload.sh <kernel notes dir> <release id> <image name>
#   e.g. sh workspace/tg5040/zerokernel/stage-payload.sh .notes/2026-11-14-tg5040-own-kernel ship2 ship2
set -eu
K=$(cd "$1" && pwd); REL=$2; NAME=$3
HERE=$(cd "$(dirname "$0")" && pwd)
OUT="$HERE/payload"
IMG="$K/work/zero-recovery-$NAME.img"
MODS="$K/work/images-$NAME"
GPU="$K/fixes/gpu/blobs/lib64"
GPU_SUMS="$(cd "$K/../2026-11-10-tortos-plastron/src/plastron/buildroot/package/pvr-ge8300" && pwd)/files.sha256"
PROCD="$K/work/fastinit/zprocd/procd"
STOCK_REC="$K/recon/recovery.bin"
case "$REL" in *[!A-Za-z0-9._-]*|'') echo "bad release id" >&2; exit 1 ;; esac

md5f() { md5 -q "$1" 2>/dev/null || md5sum "$1" | cut -d' ' -f1; }
sizef() { wc -c < "$1" | tr -d ' '; }

[ -f "$IMG" ] && [ "$(head -c 8 "$IMG")" = "ANDROID!" ] || { echo "no Android boot image at $IMG" >&2; exit 1; }
[ "$(sizef "$IMG")" -lt 15728640 ] || { echo "image overlaps the zlog MiB (15 MiB of recovery)" >&2; exit 1; }
(cd "$GPU/.." && shasum -a 256 -c "$GPU_SUMS" >/dev/null) || { echo "GPU blob checksum mismatch" >&2; exit 1; }
[ "$(sizef "$PROCD")" = 353800 ] || { echo "patched procd is not 353800 bytes (zinit's gate)" >&2; exit 1; }
[ "$(md5f "$STOCK_REC")" = 78f6f12ee2772c57527b38a71599e58a ] || { echo "stock recovery dump changed" >&2; exit 1; }

rm -rf "$OUT"; mkdir -p "$OUT/root/lib/modules/4.9.191-zero" "$OUT/root/etc/modules.d" "$OUT/root/etc/rc.d" \
	"$OUT/root/usr/lib/zero/gpu/lib" "$OUT/root/usr/lib/zero/gpu/firmware"
cp "$IMG" "$OUT/zero-recovery.img"
dd if="$STOCK_REC" of="$OUT/recovery-stock-head.bin" bs=512 count=1 2>/dev/null
cp "$MODS"/*.ko "$OUT/root/lib/modules/4.9.191-zero/"   # every module the build made, as on the dev Brick (stage/2-install.sh)
cp "$HERE/zero-xr829" "$OUT/root/etc/modules.d/zero-xr829"
for f in libEGL.so libGLESv2.so libGLES_CM.so libIMGegl.so libsrv_um.so libglslcompiler.so libusc.so libpvrNULL_WSEGL.so; do
	cp "$GPU/$f" "$OUT/root/usr/lib/zero/gpu/lib/$f"
done
cp "$GPU/firmware/rgx.fw.22.102.54.38" "$OUT/root/usr/lib/zero/gpu/firmware/"
cp "$PROCD" "$OUT/root/usr/lib/zero/procd"
cp "$HERE/S01zerogpu" "$OUT/root/etc/rc.d/S01zerogpu"
cp "$HERE/K01zeroclean" "$OUT/root/etc/rc.d/K01zeroclean"
echo "$REL" > "$OUT/root/usr/lib/zero/VERSION"
echo "$REL" > "$OUT/VERSION"

# manifest.md5: "<md5>  <overlay path>", VERSION last (zerokernel.sh swaps in this order)
( cd "$OUT/root" && find . -type f ! -path ./usr/lib/zero/VERSION | sort | while read -r p; do
	echo "$(md5f "$p")  ${p#.}"; done
  echo "$(md5f ./usr/lib/zero/VERSION)  /usr/lib/zero/VERSION" ) > "$OUT/manifest.md5"

# known-images.txt: "<bytes> <md5> <id>", every image Zero or the dev Brick ever put in recovery; the shipped one LAST
{
	for old in trim8 ship1; do
		f="$K/work/zero-recovery-$old.img"; [ "$old" = "$NAME" ] && continue
		[ -f "$f" ] && echo "$(sizef "$f") $(md5f "$f") dev-$old-$(md5f "$f" | cut -c1-8)"
	done
	echo "$(sizef "$IMG") $(md5f "$IMG") $REL-$(md5f "$IMG" | cut -c1-8)"
} > "$OUT/known-images.txt"

( cd "$OUT" && find . -type f | sort | sed 's|^\./||' | while read -r p; do echo "$(shasum -a 256 "$p" | cut -d' ' -f1)  $p"; done ) > "$HERE/payload.sha256"
echo "staged $(find "$OUT" -type f | wc -l | tr -d ' ') files, $(du -sk "$OUT" | cut -f1) KB, image $(md5f "$IMG")"
