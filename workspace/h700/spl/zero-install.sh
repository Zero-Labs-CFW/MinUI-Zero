#!/bin/sh
# On an H700 handheld (as root, from Linux): install our SPL into BROM's first slot, after pinning the card's own
# current stock boot0 twice in the reserved area the SPL restores from, and keep a copy for the deep-sleep swap
# (boot0-slot.sh, sectors 16768+). Every write is read back. Nothing is written unless the backup slot holds a valid
# stock boot0 AND the image is exactly a Zero SPL: eGON + "SPL", declared length = file size <= 48 KiB, good checksum,
# our hand-off inside. (Codex review 2026-11-05: the generic upstream SPL and the 800 KB u-boot-sunxi-with-spl.bin
# both passed the old magic-only check; the second would have overwritten the backup slot at sector 512.)
#   sh zero-install.sh /tmp/zero-spl.bin [/tmp/zero-loader.bin]
# Stage2 development is limited to Plus. Omitting the loader disables it by clearing its first sector.
set -e
case $# in
1|2) ;;
*) echo "usage: zero-install.sh <spl.bin> [loader.bin]"; exit 1 ;;
esac
SPL=$1; LOADER=${2-}
[ $# -ne 2 ] || [ -n "$LOADER" ] || { echo "empty loader argument: refusing"; exit 1; }
D=/dev/mmcblk0
PIN_A=16384; PIN_B=16512; MARK=16640; STORE=16768; MAX=49152
LSTORE=16896; LMAX=983040 # at most 1920 sectors, ending at 18816 (exclusive), below sector 19000
u32() { od -An -tu4 -j$2 -N4 "$1" | tr -d ' '; }
egon_sum_ok() {
	[ "$(od -An -tu4 -v "$1" | awk '{for(i=1;i<=NF;i++){n++; v=(n==4)?1594518585:$i; s=(s+v)%4294967296}} END{printf "%.0f", s}')" = "$(u32 "$1" 12)" ]
}
# the image first: refuse anything that is not exactly our SPL, before touching the card
[ -f "$SPL" ] || { echo "$SPL: no such file"; exit 1; }
[ "$(dd if="$SPL" bs=1 skip=4 count=8 2>/dev/null)" = eGON.BT0 ] && [ "$(dd if="$SPL" bs=1 skip=20 count=3 2>/dev/null)" = SPL ] || { echo "$SPL is not an SPL: refusing"; exit 1; }
n=$(u32 "$SPL" 16); sz=$(wc -c < "$SPL")
[ "$n" = "$sz" ] && [ "$n" -le $MAX ] && [ $((n % 512)) = 0 ] || { echo "$SPL: declared length $n, file $sz, max $MAX: refusing"; exit 1; }
egon_sum_ok "$SPL" || { echo "$SPL: bad eGON checksum: refusing"; exit 1; }
grep -a -q -F "zero: vendor hand-off" "$SPL" || { echo "$SPL has no Zero hand-off (generic upstream SPL?): refusing"; exit 1; }
# 64-byte zero_loader_hdr: magic[8], length, entry, sum, version, reserved[10]. Validate before any card write.
if [ -n "$LOADER" ]; then
	[ -f "$LOADER" ] || { echo "$LOADER: no such file"; exit 1; }
	lsz=$(wc -c < "$LOADER"); ln=$(u32 "$LOADER" 8)
	[ "$lsz" -ge 512 ] && [ "$lsz" -le $LMAX ] && [ $((lsz % 512)) = 0 ] && [ "$ln" = "$lsz" ] || { echo "$LOADER: declared length $ln, file $lsz, min 512, max $LMAX, aligned 512: refusing"; exit 1; }
	[ "$(dd if="$LOADER" bs=1 count=8 2>/dev/null)" = ZEROLDR1 ] && [ "$(u32 "$LOADER" 12)" = 64 ] && [ "$(u32 "$LOADER" 20)" = 1 ] || { echo "$LOADER: bad loader magic, entry or version: refusing"; exit 1; }
	[ "$(od -An -tu4 -v "$LOADER" | awk '{for(i=1;i<=NF;i++){n++; v=(n==5)?1594518585:$i; s=(s+v)%4294967296}} END{printf "%.0f", s}')" = "$(u32 "$LOADER" 16)" ] || { echo "$LOADER: bad loader checksum: refusing"; exit 1; }
fi
# then the backup slot: a valid stock boot0 to pin
T=/tmp/zi; rm -rf $T; mkdir -p $T
dd if=$D of=$T/stock.bin bs=512 skip=512 count=128 2>/dev/null
[ "$(dd if=$T/stock.bin bs=1 skip=4 count=8 2>/dev/null)" = "eGON.BT0" ] || { echo "backup slot is not eGON: refusing"; exit 1; }
[ "$(u32 $T/stock.bin 16)" = 65536 ] || { echo "backup slot length is not 64 KiB: refusing"; exit 1; }
[ "$(dd if=$T/stock.bin bs=1 skip=20 count=3 2>/dev/null)" != "SPL" ] || { echo "backup slot holds an SPL: refusing"; exit 1; }
egon_sum_ok $T/stock.bin || { echo "backup slot checksum bad: refusing"; exit 1; }
# Boards this SPL is proven on only. It trains LPDDR4 (upstream anbernic_rg35xx_h700_defconfig); on an LPDDR3 board
# (RG35XX Pro, RG40XX H/V: their stock boot0 says DRAM type 7) it would never bring DRAM up, and its safety net needs
# DRAM before it can restore stock: a reset loop that only a card reader fixes. The board's own stock boot0 must say
# LPDDR4 (type 8 at 0x3c) and the card must be an RG35XX H or Plus (tested 2026-11-05); other LPDDR4 boards wait for a test.
[ "$(u32 $T/stock.bin 60)" = 8 ] || { echo "this board's boot0 is not LPDDR4 (type $(u32 $T/stock.bin 60)): refusing"; exit 1; }
board=$(cat /mnt/mmc/.system/h700/board 2>/dev/null) || board=
case "$board" in
h|plus) ;;
*) echo "board '$board' is not tested with this SPL (RG35XX H and Plus are): refusing"; exit 1 ;;
esac
[ -z "$LOADER" ] || [ "$board" = plus ] || { echo "stage2 development is limited to RG35XX Plus: refusing"; exit 1; }
want=$(md5sum < $T/stock.bin | cut -c1-32)
for p in $PIN_A $PIN_B; do
	dd if=$T/stock.bin of=$D bs=512 seek=$p conv=notrunc 2>/dev/null
done
dd if=/dev/zero of=$D bs=512 seek=$MARK count=1 conv=notrunc 2>/dev/null
dd if="$SPL" of=$D bs=512 seek=$STORE conv=notrunc 2>/dev/null
sync; echo 3 > /proc/sys/vm/drop_caches
for p in $PIN_A $PIN_B; do
	[ "$(dd if=$D bs=512 skip=$p count=128 2>/dev/null | md5sum | cut -c1-32)" = "$want" ] || { echo "PIN READBACK FAILED at $p"; exit 1; }
done
[ "$(dd if=$D bs=512 skip=$STORE count=$((n / 512)) 2>/dev/null | md5sum | cut -c1-32)" = "$(md5sum < "$SPL" | cut -c1-32)" ] || { echo "STORE READBACK FAILED"; exit 1; }
# Invalidate the old loader first, then verify the body before publishing its header sector (and finally the SPL).
dd if=/dev/zero of=$D bs=512 seek=$LSTORE count=1 conv=notrunc 2>/dev/null
sync; echo 3 > /proc/sys/vm/drop_caches
[ "$(dd if=$D bs=512 skip=$LSTORE count=1 2>/dev/null | md5sum | cut -c1-32)" = "$(dd if=/dev/zero bs=512 count=1 2>/dev/null | md5sum | cut -c1-32)" ] || { echo "LOADER HEADER CLEAR READBACK FAILED"; exit 1; }
if [ -n "$LOADER" ]; then
	dd if="$LOADER" of=$D bs=512 skip=1 seek=$((LSTORE + 1)) count=$((ln / 512 - 1)) conv=notrunc 2>/dev/null
	sync; echo 3 > /proc/sys/vm/drop_caches
	[ "$(dd if=$D bs=512 skip=$((LSTORE + 1)) count=$((ln / 512 - 1)) 2>/dev/null | md5sum | cut -c1-32)" = "$(dd if="$LOADER" bs=512 skip=1 count=$((ln / 512 - 1)) 2>/dev/null | md5sum | cut -c1-32)" ] || { echo "LOADER BODY READBACK FAILED"; exit 1; }
	dd if="$LOADER" of=$D bs=512 count=1 seek=$LSTORE conv=notrunc 2>/dev/null
	sync; echo 3 > /proc/sys/vm/drop_caches
	[ "$(dd if=$D bs=512 skip=$LSTORE count=$((ln / 512)) 2>/dev/null | md5sum | cut -c1-32)" = "$(md5sum < "$LOADER" | cut -c1-32)" ] || { echo "LOADER READBACK FAILED"; exit 1; }
	echo "stage 2 installed at $LSTORE ($ln bytes)"
else
	echo "stage 2 disabled (header cleared at $LSTORE)"
fi
# slot 16 last, body first and header last (a torn write fails BROM's checksum and boots the stock backup slot)
dd if="$SPL" of=$D bs=512 skip=1 seek=17 count=$((n / 512 - 1)) conv=notrunc 2>/dev/null
sync
dd if="$SPL" of=$D bs=512 count=1 seek=16 conv=notrunc 2>/dev/null
sync; echo 3 > /proc/sys/vm/drop_caches
[ "$(dd if=$D bs=512 skip=16 count=$((n / 512)) 2>/dev/null | md5sum | cut -c1-32)" = "$(md5sum < "$SPL" | cut -c1-32)" ] || { echo "SPL READBACK FAILED"; exit 1; }
rm -f /opt/minui-zero/.spl-sleep-swapped
busybox devmem 0x07000138 32 0; busybox devmem 0x0700013c 32 0
echo "installed: stock $want pinned at $PIN_A and $PIN_B, SPL in slot 16 and kept at $STORE, backup slot 512 untouched, markers clear"
