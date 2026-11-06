#!/bin/sh
# Our first-stage loader for the H700 boards (boot speed, 2026-11-05): upstream U-Boot v2026.10 SPL (DRAM, PMIC) plus
# zero-spl.patch, which hands off to the card's own vendor monitor and U-Boot the way Allwinner's boot0 does:
#   arch/arm/mach-sunxi/zero_vendor.c  the hand-off (boot0's U-Boot/monitor header contract, the PLLs stock boot0 leaves
#                                      on, D-cache), boot-time stamps in RTC general-purpose registers, and the safety
#                                      net: pinned stock boot0 copies at sectors 16384/16512, an attempt flag (RTC GP15
#                                      + on-card marker at 16640) that puts stock back if a boot never acknowledges
#   arch/arm/mach-sunxi/zero_dram_check.h  which units a build may train (universal SPL, 2026-11-06): the unit binding
#                                      at 16641 (SID + the pinned DRAM words), checked before PMIC and DRAM; anything
#                                      else puts stock back first
#   board.c hooks                      spl_board_load_image / zero_vendor_early on H616-family builds only
#   drivers/mmc/sunxi_mmc.c            DMA (IDMAC) for large SPL reads, retry without high speed on a failed init
# Two builds, one per DRAM type (DRAM type is per unit, not per board: the Pro and 40XX H ship both):
#   zero-spl.bin      LPDDR4, anbernic_rg35xx_h700_defconfig (mainline delays, DCDC3 1.1 V): the RG35XX H/Plus build
#   zero-spl-lp3.bin  LPDDR3: the LPDDR3 electricals every staged boot0 carries, DCDC3 1.2 V, the unit's own trained
#                     tpr6/11/12 from the binding (set at run time, never from Kconfig)
# Both: + CONFIG_SPL_MMC_WRITE (the safety net writes the card) + BSS in SRAM. The map and ELF of each go next to it.
# Install on a device with zero-install.sh; Linux side: tools/h700-strip/boot0-slot.sh (deep sleep swap, boot ack).
#   sh workspace/h700/spl/build.sh [cache dir]      -> <cache dir>/zero-spl.bin, zero-spl-lp3.bin (+ .map, .elf)
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
[ -z "$(git -C /c/u-boot status --porcelain)" ] && [ -z "$(git -C /c/u-boot clean -xdn)" ] ||
	{ echo "ERROR: the cached u-boot has local changes or build products: delete it"; exit 1; }
for T in lp4 lp3; do
rm -rf /tmp/u && cp -a /c/u-boot /tmp/u && cd /tmp/u
git apply /c/zero-spl.patch
: > .scmversion	# reproducible: no "-dirty" from the applied patch, and the build date is the upstream commit date
export SOURCE_DATE_EPOCH=$(git log -1 --format=%ct)
make -s anbernic_rg35xx_h700_defconfig
./scripts/config --enable SPL_MMC_WRITE
# H616 boots only the vendor chain, not FIT; keep SRAM for recovery and stage2 guards.
./scripts/config --disable SPL_FIT --disable SPL_LOAD_FIT --disable SPL_HASH --disable SPL_OF_LIBFDT
./scripts/config --disable SPL_LEGACY_IMAGE_FORMAT
# BSS in SRAM right after the SPL (it ends at 0x2c000; BROM loads 64 KiB stock boot0 here): the safety net runs before DRAM
./scripts/config --set-val SPL_BSS_START_ADDR 0x2c000 --set-val SPL_BSS_MAX_SIZE 0x4000
# CPU rail (AXP717/2202 DCDC1) to 1.1 V before the SPL raises the CPU to 1008 MHz, as stock boot0 does: upstream never
# sets it, so after a warm reset the CPU ran at 1008 MHz on the 0.9 V Linux left at idle (warm-reboot hangs, 2026-11-06)
./scripts/config --set-val AXP_DCDC1_VOLT 1100
if [ $T = lp3 ]; then
	# The LPDDR3 set in every staged boot0 (37d7397f, and the 672/7 bank of all the others); zero_dram_check.h refuses
	# a unit whose words differ, and fails the build if these and its table disagree. DCDC3 1.2 V: BaseOS measured it
	# on its LPDDR3 RG40XX V under stock (unverified by us). Trained delays: the unit binding, at run time.
	./scripts/config --disable SUNXI_DRAM_H616_LPDDR4 --enable SUNXI_DRAM_H616_LPDDR3 \
		--set-val DRAM_SUNXI_DX_ODT 0x06060606 --set-val DRAM_SUNXI_DX_DRI 0x0d0d0d0d \
		--set-val DRAM_SUNXI_CA_DRI 0x1919 --set-val DRAM_SUNXI_ODT_EN 0x9988eeee \
		--set-val DRAM_SUNXI_TPR10 0x402f4489 --set-val DRAM_SUNXI_TPR6 0 \
		--set-val DRAM_SUNXI_TPR11 0 --set-val DRAM_SUNXI_TPR12 0 --set-val AXP_DCDC3_VOLT 1200
fi
make -s olddefconfig
grep -q "^CONFIG_AXP_DCDC1_VOLT=1100$" .config || { echo "ERROR: the CPU rail (DCDC1) is not set to 1100 mV"; exit 1; }
if grep -Eq "^CONFIG_SPL_(FIT|LOAD_FIT|HASH|OF_LIBFDT|LEGACY_IMAGE_FORMAT)=y$" .config; then
    echo "ERROR: an unused SPL image loader was selected again"; exit 1
fi
if [ $T = lp3 ]; then
	grep -q "^CONFIG_SUNXI_DRAM_H616_LPDDR3=y$" .config && grep -q "^CONFIG_AXP_DCDC3_VOLT=1200$" .config &&
		! grep -q "^CONFIG_SUNXI_DRAM_H616_LPDDR4=y$" .config || { echo "ERROR: the LPDDR3 build is not LPDDR3 at 1.2 V"; exit 1; }
	O=zero-spl-lp3
else
	grep -q "^CONFIG_SUNXI_DRAM_H616_LPDDR4=y$" .config && grep -q "^CONFIG_AXP_DCDC3_VOLT=1100$" .config ||
		{ echo "ERROR: the LPDDR4 build is not LPDDR4 at 1.1 V"; exit 1; }
	O=zero-spl
fi
grep -q "^CONFIG_DRAM_SUNXI_PHY_ADDR_MAP_1=y$" .config || { echo "ERROR: not the H700 PHY map (map 1)"; exit 1; }
make -s -j"$(nproc)" spl/sunxi-spl.bin > /tmp/b.log 2>&1 || { tail -30 /tmp/b.log; exit 1; }
! grep -E "warning|error" /tmp/b.log || { echo "ERROR: build warnings"; exit 1; }
S=spl/sunxi-spl.bin
[ "$(wc -c < $S)" -le 49152 ] || { echo "ERROR: SPL over 48 KiB"; exit 1; }
# code and data must end below the SRAM BSS (0x2c000)
END=$(sed -n "s/^ *0x0*\([0-9a-f]*\) *_end = \.$/\1/p" spl/u-boot-spl.map)
[ -n "$END" ] && [ $((0x$END)) -le $((0x2c000)) ] || { echo "ERROR: SPL image end 0x$END overlaps the SRAM BSS"; exit 1; }
grep -a -q -F "zero: vendor hand-off" $S || { echo "ERROR: no Zero hand-off in the SPL"; exit 1; }
grep -a -q -F "zero: dram $T" $S || { echo "ERROR: the SPL does not carry its DRAM type ($T)"; exit 1; }
echo "$O: _end 0x$END, $((0x2c000 - 0x$END)) bytes free below the BSS"
cp spl/u-boot-spl.map /c/$O.map; cp spl/u-boot-spl /c/$O.elf
cp $S /c/$O.bin.part && mv /c/$O.bin.part /c/$O.bin
cd /
done
'
echo "built $CACHE/zero-spl.bin ($(wc -c < "$CACHE/zero-spl.bin") bytes), $CACHE/zero-spl-lp3.bin ($(wc -c < "$CACHE/zero-spl-lp3.bin") bytes)"
