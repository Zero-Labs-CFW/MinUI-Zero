#!/bin/bash
# Build zero_late_usb.ko against stock Linux 4.9.170 configured like the H700 vendor kernels (config.h700, taken from
# the RG35XX H's /proc/config.gz), inside tg5040-toolchain (GCC 8.3, the vendor kernels' compiler generation).
# Module.symvers is generated from a vendor kernel image by tools/h700-image/symcrc.py: the CRCs of the symbols the
# module uses are identical in all 8 of our kernels (checked 2026-11-04). Usage, from the repo root:
#   sh workspace/h700/late-usb/build.sh <cache dir> <a board kernel: p4-kernel.img.gz>
set -e
CACHE=$1; KIMG=$2
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../../.." && pwd)
TAR=linux-4.9.170.tar.xz; SUM=33887b40fc8e0b71f423bb7afe112a4ae190378145f4a3f3892c563b7e43131d
mkdir -p "$CACHE"
if [ ! -f "$CACHE/$TAR" ]; then
	curl -fsSL "https://cdn.kernel.org/pub/linux/kernel/v4.x/$TAR" -o "$CACHE/$TAR.part"
	mv "$CACHE/$TAR.part" "$CACHE/$TAR"
fi
[ "$(shasum -a 256 "$CACHE/$TAR" | cut -d' ' -f1)" = "$SUM" ] || { echo "ERROR: $TAR checksum"; exit 1; }
python3 "$REPO/tools/h700-image/symcrc.py" "$KIMG" module_layout printk of_find_compatible_node of_find_property \
	of_platform_device_create __stack_chk_fail __stack_chk_guard strcmp | grep '^0x' > "$CACHE/Module.symvers"
cp "$HERE/config.h700" "$CACHE/config.h700"
rm -rf "$CACHE/src"; mkdir -p "$CACHE/src"; cp "$HERE/zero_late_usb.c" "$CACHE/src/"
docker run --rm --platform linux/amd64 -v "$CACHE:/k" tg5040-toolchain bash -c '
set -e
export ARCH=arm64 CROSS_COMPILE=/opt/aarch64-linux-gnu/bin/aarch64-linux-gnu-
cd /tmp && tar xf /k/'"$TAR"' && cd linux-4.9.170
cp /k/config.h700 .config && make olddefconfig >/dev/null && make -j8 modules_prepare >/tmp/prep.log 2>&1 || { tail -30 /tmp/prep.log; exit 1; }
cp /k/Module.symvers Module.symvers
cp -r /k/src /tmp/m && cd /tmp/m && echo "obj-m := zero_late_usb.o" > Kbuild
make -C /tmp/linux-4.9.170 M=/tmp/m modules >/tmp/m.log 2>&1 || { cat /tmp/m.log; exit 1; }
${CROSS_COMPILE}strip --strip-debug zero_late_usb.ko && cp zero_late_usb.ko /k/zero_late_usb.ko'
strings "$CACHE/zero_late_usb.ko" | grep -qx "vermagic=4.9.170 SMP preempt mod_unload modversions aarch64" || { echo "ERROR: vermagic"; exit 1; }
echo "built $CACHE/zero_late_usb.ko"
