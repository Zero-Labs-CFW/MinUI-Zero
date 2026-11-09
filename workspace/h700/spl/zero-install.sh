#!/bin/sh
# On an H700 handheld (as root, from Linux): install our SPL into BROM's first slot, after pinning the card's own
# current stock boot0 twice in the reserved area the SPL restores from, and keep a copy for the deep-sleep swap
# (boot0-slot.sh, sectors 16768+). Every write is read back. Nothing is written unless the backup slot holds a valid
# stock boot0 AND the image is exactly a Zero SPL: eGON + "SPL", declared length = file size <= 48 KiB, good checksum,
# our hand-off inside. (Codex review 2026-11-05: the generic upstream SPL and the 800 KB u-boot-sunxi-with-spl.bin
# both passed the old magic-only check; the second would have overwritten the backup slot at sector 512.)
#   sh zero-install.sh /tmp/zero-spl.bin [/tmp/zero-loader.bin]
# Stage2: Plus development path; LPDDR4 H requires ZERO_STAGE2_TRIAL=1 for an attended bench trial.
# Other boards still refuse. Omitting the loader disables it by clearing its first sector.
# Universal SPL (2026-11-06): two builds, one per DRAM type (zero-spl.bin LPDDR4, zero-spl-lp3.bin LPDDR3; the SPL says
# which with "zero: dram lp4|lp3"). This unit's own stock boot0 (backup slot) must describe exactly what that build
# trains (dram_check: the rules of the SPL's zero_dram_check.h), and the SPL is bound to this unit: a binding sector at
# 16641 holds its SID (from androidboot.serialno) and its pinned DRAM words, which the SPL checks before PMIC and DRAM.
# Qualified on hardware: LPDDR4 on the RG35XX H and Plus. Any other board/type is a bench trial (ZERO_SPL_TRIAL=1), and
# ZERO_SPL_KEYTEST=1 installs a build of the OTHER type on an H/Plus on purpose: its SPL must refuse and put stock back.
#   sh zero-install.sh --check <boot0> <spl.bin> <serial> <binding out>   (host tests: the verdict, no card access)
set -e
case $# in
1|2|5|6) ;;
*) echo "usage: zero-install.sh <spl.bin> [loader.bin]"; exit 1 ;;
esac
SPL=$1; LOADER=${2-}
[ $# -ne 2 ] || [ -n "$LOADER" ] || { echo "empty loader argument: refusing"; exit 1; }
D=/dev/mmcblk0
PIN_A=16384; PIN_B=16512; MARK=16640; BIND=16641; STORE=16768; MAX=49152
LSTORE=16896; LMAX=983040 # at most 1920 sectors, ending at 18816 (exclusive), below sector 19000
u32() { od -An -tu4 -j$2 -N4 "$1" | tr -d ' '; }
stage2_board_ok() {
	case "${1-}:${2-}" in
	plus:7|plus:8) return 0 ;;
	h:8) [ "${ZERO_STAGE2_TRIAL-}" = 1 ] ;;
	*) return 1 ;;
	esac
}
stage2_consumer_ok() {
	[ -f "$1" ] && [ -x "$2" ] && [ -f "$3" ] || return 1
	_ack=$(sh "$1" stage2-contract) || return 1
	[ "$_ack" = zero-stage2-health-v1 ] || return 1
	_health=$("$2" --contract) || return 1
	[ "$_health" = zero-stage2-health-v1 ] || return 1
	_id=$(cat "$3") || return 1
	[ "${#_id}" = 64 ] || return 1
	case "$_id" in *[!0-9a-f]*) return 1 ;; esac
}
egon_sum_ok() {
	[ "$(od -An -tu4 -v "$1" | awk '{for(i=1;i<=NF;i++){n++; v=(n==4)?1594518585:$i; s=(s+v)%4294967296}} END{printf "%.0f", s}')" = "$(u32 "$1" 12)" ]
}
# 0 when a build of DRAM type $2 (7 LPDDR3, 8 LPDDR4) may train the words of boot0 $1, else the SPL's refusal reason
# (zero_dram_check.h, same numbers). The SID's PHY map and the PMIC only the SPL can read; it checks them itself.
dram_check() {
	od -An -tu4 -v -j56 -N128 "$1" | awk -v t="$2" '{for(i=1;i<=NF;i++) w[n++]=$i}
	END {
		lp4 = (t == 8)
		if (n != 32) { print 1; exit }
		if (w[0] != 672) { print 5; exit }
		if (w[1] != t || (t != 7 && t != 8)) { print 6; exit }
		if (w[2] != (lp4 ? 134744072 : 101058054) || w[3] != (lp4 ? 235802126 : 218959117) ||
		    w[4] != (lp4 ? 3598 : 6425) || w[5] != (lp4 ? 2022161339 : 2575888110)) { print 7; exit }
		split(lp4 ? "0 52 27 51 3 0 0 4 114 0 9 0 0 36" : "0 131 28 1 0 0 0 0 0 0 0 0 0 0", mr, " ")
		for (i = 0; i < 14; i++) if (w[8 + i] != mr[i + 1]) { print 8; exit }
		if (w[22] != 0 || w[24] != 1 || w[27] != (lp4 ? 1076848179 : 1076839561)) { print 9; exit }
		sz = int(w[7] / 65536); lo = w[7] % 65536
		if ((sz != 1024 && sz != 2048) || (lo != 0 && lo != 4096)) { print 10; exit }
		if (!lp4 && (w[28] == 0 || w[29] == 0 || int(w[26] / 65536) % 256 == 0)) { print 11; exit }
		print 0 }'
}
le32() { printf '%b' "$(printf '\\0%03o\\0%03o\\0%03o\\0%03o' $(($1 & 255)) $(($1 >> 8 & 255)) $(($1 >> 16 & 255)) $(($1 >> 24 & 255)))"; }
# the unit binding (zero_dram_check.h): magic, SID word 1 >> 20, word 2, word 3 (the serial's 3+8+8 hex digits), 0,
# the 32 DRAM words of boot0 $1; $2 the serial, $3 the 512-byte output
make_bind() {
	case "$2" in *[!0123456789abcdef]*|'') return 1 ;; esac		# one serial, lower-case hex only (no second line)
	[ ${#2} = 19 ] && [ "$2" != 0000000000000000000 ] || return 1
	{ printf 'ZERO-BIND-V1\000\000\000\000'
	  le32 $((0x$(echo "$2" | cut -c1-3))); le32 $((0x$(echo "$2" | cut -c4-11))); le32 $((0x$(echo "$2" | cut -c12-19))); le32 0
	  dd if="$1" bs=1 skip=56 count=128 2>/dev/null; dd if=/dev/zero bs=1 count=352 2>/dev/null; } > "$3"
	[ "$(wc -c < "$3")" -eq 512 ]
}
# a string in a binary: NULs to newlines first, since busybox grep -a compares line by line with strstr and a NUL before
# the string on its "line" hides it (it never found "zero: vendor hand-off" in any build, 2026-11-06)
has_str() { LC_ALL=C tr '\000' '\n' < "$1" | grep -c -F "$2" || :; }
spl_type() { # 8 or 7 from the SPL's own "zero: dram lp4|lp3", empty if it says neither (or both)
	_4=$(has_str "$1" "zero: dram lp4"); _3=$(has_str "$1" "zero: dram lp3")
	if [ "$_4" != 0 ] && [ "$_3" = 0 ]; then echo 8; elif [ "$_3" != 0 ] && [ "$_4" = 0 ]; then echo 7; fi
}
# The SID the SPL will read (0x03006200..0x0300620c) against the serial: vendor U-Boot prints "%03x%08x%08x" of
# word 1 >> 20, word 2, word 3 (0x4a00500c), but only when the env has no snum of its own, so the two can differ.
# Matching on the RG35XX H (9c001070c710c901e52) and Plus (6c0010716544c921c12), read 2026-11-06. Also stock's PHY-map
# rule on word 0 (zero_dram_check.h). Prints 0, or the SPL's reason: 3 serial is not this SID, 4 PHY map 0.
sid_check() { # <serial> <word0> <word1> <word2> <word3> (any shell number form)
	[ "$(printf '%03x%08x%08x' $(($3 >> 20)) $(($4)) $(($5)))" = "$1" ] || { echo 3; return; }
	w=$(($2 & 65535))
	if [ $((w & 0xfbff)) = $((0x5000)) ] || [ $((w & 0xfeff)) = $((0x5c00)) ] || [ $((w & 0xf7ff)) = $((0x2000)) ]; then
		echo 4; return
	fi
	echo 0
}
if [ "$1" = --sid-check ]; then
	[ $# = 6 ] || { echo "usage: zero-install.sh --sid-check <serial> <sid0> <sid1> <sid2> <sid3>"; exit 1; }
	sid_check "$2" "$3" "$4" "$5" "$6"; exit 0
fi
if [ "$1" = --check ]; then
	[ $# = 5 ] || { echo "usage: zero-install.sh --check <boot0> <spl.bin> <serial> <binding out>"; exit 1; }
	st=$(spl_type "$3"); [ -n "$st" ] || { echo "notype"; exit 1; }
	r=$(dram_check "$2" "$st"); make_bind "$2" "$4" "$5" || { echo "$r noserial"; exit 1; }
	echo "$r"; exit 0
fi
[ $# -le 2 ] || { echo "usage: zero-install.sh <spl.bin> [loader.bin]"; exit 1; }
# the image first: refuse anything that is not exactly our SPL, before touching the card
[ -f "$SPL" ] || { echo "$SPL: no such file"; exit 1; }
[ "$(dd if="$SPL" bs=1 skip=4 count=8 2>/dev/null)" = eGON.BT0 ] && [ "$(dd if="$SPL" bs=1 skip=20 count=3 2>/dev/null)" = SPL ] || { echo "$SPL is not an SPL: refusing"; exit 1; }
n=$(u32 "$SPL" 16); sz=$(wc -c < "$SPL")
[ "$n" = "$sz" ] && [ "$n" -le $MAX ] && [ $((n % 512)) = 0 ] || { echo "$SPL: declared length $n, file $sz, max $MAX: refusing"; exit 1; }
egon_sum_ok "$SPL" || { echo "$SPL: bad eGON checksum: refusing"; exit 1; }
[ "$(has_str "$SPL" "zero: vendor hand-off")" != 0 ] || { echo "$SPL has no Zero hand-off (generic upstream SPL?): refusing"; exit 1; }
ST=$(spl_type "$SPL"); [ -n "$ST" ] || { echo "$SPL does not say which DRAM type it trains (an older build?): refusing"; exit 1; }
# 64-byte v2 header: magic[8], length, entry, sum, version, preflight, reserved[9]. Validate before any card write.
if [ -n "$LOADER" ]; then
	[ -f "$LOADER" ] || { echo "$LOADER: no such file"; exit 1; }
	lsz=$(wc -c < "$LOADER"); ln=$(u32 "$LOADER" 8)
	[ "$lsz" -ge 512 ] && [ "$lsz" -le $LMAX ] && [ $((lsz % 512)) = 0 ] && [ "$ln" = "$lsz" ] || { echo "$LOADER: declared length $ln, file $lsz, min 512, max $LMAX, aligned 512: refusing"; exit 1; }
	[ "$(dd if="$LOADER" bs=1 count=8 2>/dev/null)" = ZEROLDR1 ] && [ "$(u32 "$LOADER" 12)" = 64 ] && [ "$(u32 "$LOADER" 20)" = 2 ] || { echo "$LOADER: bad loader magic, entry or version: refusing"; exit 1; }
	pf=$(u32 "$LOADER" 24)
	[ "$pf" -ge 64 ] && [ "$pf" -le $((ln - 4)) ] && [ $((pf % 4)) = 0 ] || { echo "$LOADER: invalid preflight entry: refusing"; exit 1; }
	[ "$(dd if="$LOADER" bs=1 skip=28 count=36 2>/dev/null | tr -d '\000' | wc -c)" -eq 0 ] || { echo "$LOADER: nonzero reserved header: refusing"; exit 1; }
	[ "$(od -An -tu4 -v "$LOADER" | awk '{for(i=1;i<=NF;i++){n++; v=(n==5)?1594518585:$i; s=(s+v)%4294967296}} END{printf "%.0f", s}')" = "$(u32 "$LOADER" 16)" ] || { echo "$LOADER: bad loader checksum: refusing"; exit 1; }
fi
# then the backup slot: a valid stock boot0 to pin
T=/tmp/zi; rm -rf $T; mkdir -p $T
dd if=$D of=$T/stock.bin bs=512 skip=512 count=128 2>/dev/null
[ "$(dd if=$T/stock.bin bs=1 skip=4 count=8 2>/dev/null)" = "eGON.BT0" ] || { echo "backup slot is not eGON: refusing"; exit 1; }
[ "$(u32 $T/stock.bin 16)" = 65536 ] || { echo "backup slot length is not 64 KiB: refusing"; exit 1; }
[ "$(dd if=$T/stock.bin bs=1 skip=20 count=3 2>/dev/null)" != "SPL" ] || { echo "backup slot holds an SPL: refusing"; exit 1; }
egon_sum_ok $T/stock.bin || { echo "backup slot checksum bad: refusing"; exit 1; }
# This unit, not this board: DRAM type and trained words come from its own stock boot0 (the vendor chain writes them
# back to both slots on every stock boot). A first install (stock in slot 16) needs both slots to agree, so the backup
# slot is what this unit's last stock boot wrote, not a boot0 copied over from elsewhere (board picker, card swap).
PT=$(u32 $T/stock.bin 60)
dd if=$D of=$T/slot16.bin bs=512 skip=16 count=128 2>/dev/null
if [ "$(dd if=$T/slot16.bin bs=1 skip=20 count=3 2>/dev/null)" != SPL ]; then
	cmp -s $T/slot16.bin $T/stock.bin || { echo "slot 16 and the backup slot hold different stock boot0s: boot stock once, then retry"; exit 1; }
fi
sn=$(tr ' ' '\n' < /proc/cmdline | sed -n 's/^androidboot.serialno=//p')
make_bind $T/stock.bin "$sn" $T/bind.bin || { echo "no usable SID serial in /proc/cmdline ('$sn'): refusing"; exit 1; }
sid0=$(busybox devmem 0x03006200 32) && sid1=$(busybox devmem 0x03006204 32) && sid2=$(busybox devmem 0x03006208 32) &&
	sid3=$(busybox devmem 0x0300620c 32) || { echo "cannot read the SID: refusing"; exit 1; }
case "$(sid_check "$sn" "$sid0" "$sid1" "$sid2" "$sid3")" in
0) ;;
3) echo "the serial ($sn) is not this chip's SID ($sid1 $sid2 $sid3; an snum in the U-Boot env?): refusing"; exit 1 ;;
*) echo "stock boot0 wires this chip with PHY map 0 (SID $sid0); our builds are map 1: refusing"; exit 1 ;;
esac
# a boot0 copied from the image (board picker) carries the image's trained words, not this unit's: boot stock first
for f in /opt/minui-zero/boards/*/boot0.img; do
	[ -f "$f" ] || continue
	! cmp -s "$f" $T/stock.bin || { echo "the backup slot holds the shipped $f, not this unit's own: boot stock once, then retry"; exit 1; }
done
board=$(cat /mnt/mmc/.system/h700/board 2>/dev/null) || board=
r=$(dram_check $T/stock.bin $ST)
if [ "${ZERO_SPL_KEYTEST-}" = 1 ]; then
	# the safety test: a build of the other type on a good LPDDR4 H/Plus; its SPL refuses (reason 6) before PMIC and DRAM
	case "$board" in h|plus) ;; *) echo "the key test runs on an RG35XX H or Plus only: refusing"; exit 1 ;; esac
	[ "$PT" = 8 ] && [ "$ST" = 7 ] && [ "$(dram_check $T/stock.bin 8)" = 0 ] && [ "$r" = 6 ] && [ -z "$LOADER" ] ||
		{ echo "key test: needs the LPDDR3 build, no loader, on a unit whose boot0 passes as LPDDR4: refusing"; exit 1; }
	echo "KEY TEST: installing an LPDDR3 build on this LPDDR4 unit; it must restore stock by itself on the next start"
else
	[ "$r" = 0 ] || { echo "this unit's boot0 (DRAM type $PT) is not one this build (type $ST) trains (reason $r): refusing"; exit 1; }
	case "$ST:$board" in
	8:h|8:plus) ;;	# qualified on hardware 2026-11-05/06
	*) [ "${ZERO_SPL_TRIAL-}" = 1 ] || { echo "board '$board' with DRAM type $ST is not qualified (LPDDR4 RG35XX H and Plus are); a bench trial needs ZERO_SPL_TRIAL=1: refusing"; exit 1; }
	   echo "TRIAL: board '$board', DRAM type $ST: not qualified, the safety net is all there is" ;;
	esac
fi
if [ -n "$LOADER" ]; then
	stage2_board_ok "$board" "$ST" || { echo "stage2 needs RG35XX Plus, or LPDDR4 H with ZERO_STAGE2_TRIAL=1: refusing"; exit 1; }
	stage2_consumer_ok /opt/minui-zero/boot0-slot.sh /opt/minui-zero/loader/boot-health \
		/opt/minui-zero/loader/build-id || { echo 'stage2 needs the health-v1 acknowledgment rootfs: refusing'; exit 1; }
	[ "$board" != h ] || echo "TRIAL: stage2 on LPDDR4 RG35XX H; this is not hardware qualification"
fi
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
# the unit binding (before the SPL goes in: an SPL without it refuses and puts stock back)
dd if=$T/bind.bin of=$D bs=512 seek=$BIND conv=notrunc 2>/dev/null
sync; echo 3 > /proc/sys/vm/drop_caches
[ "$(dd if=$D bs=512 skip=$BIND count=1 2>/dev/null | md5sum | cut -c1-32)" = "$(md5sum < $T/bind.bin | cut -c1-32)" ] || { echo "BINDING READBACK FAILED"; exit 1; }
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
busybox devmem 0x07000134 32 0; busybox devmem 0x07000138 32 0; busybox devmem 0x0700013c 32 0	# crumbs + validated record, GP14, GP15
echo "installed: stock $want pinned at $PIN_A and $PIN_B, bound to this unit at $BIND, SPL (DRAM type $ST) in slot 16 and kept at $STORE, backup slot 512 untouched, markers clear"
