#!/bin/sh
# Our first-stage loader for the H700 boards (boot speed, 2026-11-05): upstream U-Boot v2026.10 SPL (DRAM, PMIC) plus
# zero-spl.patch, which hands off to the card's own vendor monitor and U-Boot the way Allwinner's boot0 does:
#   arch/arm/mach-sunxi/zero_vendor.c  the hand-off (boot0's U-Boot/monitor header contract, the PLLs stock boot0 leaves
#                                      on, D-cache), boot-time stamps in RTC general-purpose registers, and the safety
#                                      net: pinned stock boot0 copies at sectors 16384/16512, an attempt flag (RTC GP15
#                                      + on-card marker at 16640) that puts stock back if a boot never acknowledges
#   board.c hooks                      spl_board_load_image / zero_vendor_early on H616-family builds only
#   drivers/mmc/sunxi_mmc.c            DMA (IDMAC) for large SPL reads, retry without high speed on a failed init
# Config: anbernic_rg35xx_h700_defconfig + CONFIG_SPL_MMC_WRITE (the safety net writes the card).
# Install on a device with zero-install.sh; Linux side: tools/h700-strip/boot0-slot.sh (deep sleep swap, boot ack).
#   sh workspace/h700/spl/build.sh [cache dir]      -> <cache dir>/zero-spl.bin
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
CACHE=${1:-$HERE/build}
UBOOT_TAG=v2026.10; UBOOT_COMMIT=5508406582f6f7120dce0c4b3059819a41788db2
mkdir -p "$CACHE"
cp "$HERE/zero-spl.patch" "$CACHE/zero-spl.patch"
docker run --rm --platform linux/arm64 -v "$CACHE:/c" debian:bookworm sh -ec '
apt-get update -qq >/dev/null
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends git ca-certificates make gcc libc6-dev \
  bison flex python3 python3-setuptools python3-pyelftools python3-dev swig libssl-dev libgnutls28-dev device-tree-compiler \
  bc >/dev/null
[ -d /c/u-boot ] || git clone -q --depth 1 --branch '"$UBOOT_TAG"' https://source.denx.de/u-boot/u-boot.git /c/u-boot
[ "$(git -C /c/u-boot rev-parse HEAD)" = '"$UBOOT_COMMIT"' ] || { echo "ERROR: u-boot is not '"$UBOOT_TAG"' ('"$UBOOT_COMMIT"')"; exit 1; }
[ -z "$(git -C /c/u-boot status --porcelain)" ] || { echo "ERROR: the cached u-boot has local changes: delete it"; exit 1; }
rm -rf /tmp/u && cp -a /c/u-boot /tmp/u && cd /tmp/u
git apply /c/zero-spl.patch
: > .scmversion	# reproducible: no "-dirty" from the applied patch, and the build date is the upstream commit date
export SOURCE_DATE_EPOCH=$(git log -1 --format=%ct)
make -s anbernic_rg35xx_h700_defconfig
./scripts/config --enable SPL_MMC_WRITE
make -s olddefconfig
make -s -j"$(nproc)" spl/sunxi-spl.bin > /tmp/b.log 2>&1 || { tail -30 /tmp/b.log; exit 1; }
! grep -E "warning|error" /tmp/b.log || { echo "ERROR: build warnings"; exit 1; }
S=spl/sunxi-spl.bin
[ "$(wc -c < $S)" -le 49152 ] || { echo "ERROR: SPL over 48 KiB"; exit 1; }
grep -a -q -F "zero: vendor hand-off" $S || { echo "ERROR: no Zero hand-off in the SPL"; exit 1; }
cp $S /c/zero-spl.bin.part && mv /c/zero-spl.bin.part /c/zero-spl.bin
'
echo "built $CACHE/zero-spl.bin ($(wc -c < "$CACHE/zero-spl.bin") bytes)"
