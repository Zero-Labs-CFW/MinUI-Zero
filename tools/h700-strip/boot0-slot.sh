#!/bin/sh
# Deep sleep with our SPL (option A, 2026-11-05). Waking from suspend-to-RAM reboots the SoC through BROM's first slot;
# stock boot0 sees the RTC "resuming" flag (0x070001f8 bit 16), brings DRAM back without clearing it and jumps to the
# monitor's warm entry (0x070001fc). Our SPL cannot resume (it retrains DRAM, wiping the sleeping system), so stock
# boot0 sits in slot 16 for the length of a sleep:
#   boot0-slot.sh store <spl.bin>  keep a copy of our SPL in reserved sectors 16768+ (zero-install.sh does this)
#   boot0-slot.sh stock            before `echo mem`: the pinned stock boot0 (16384) into slot 16
#   boot0-slot.sh ours             after the wake: our SPL back into slot 16, ONLY if this sleep swapped it out
#   boot0-slot.sh boot             at boot: finish an interrupted swap (same rule as ours)
#   boot0-slot.sh ack              background, at boot: once the menu (or a resumed game) is on screen, acknowledge a
#                                  boot through our SPL (RTC GP15 and the on-card marker at 16640), so its safety net
#                                  keeps it installed; an unacknowledged attempt is put back to stock on the next start
# A card without our SPL (every card today) has nothing stored at 16768: every action is then a no-op.
# The flag file is the proof that a sleep swapped our SPL out: without it, ours does nothing, so a sleep can never
# re-enable an SPL that the SPL's own safety net removed after a failed boot (Codex review 2026-11-05).
# Writes go body first, header last, and are verified in full: a power loss mid-write leaves slot 16 with a bad
# checksum, BROM boots the backup slot (512, always stock), and the flag (still set) finishes the job next boot.
D=/dev/mmcblk0
# the suspend script closes stdin (exec 0<&-): busybox od then still prints the value but also an error and exits 1
exec 0</dev/null
SLOT=16; PIN=16384; PIN_B=16512; STORE=16768; STORE_N=96
FLAG=/opt/minui-zero/.spl-sleep-swapped
# reads go around the page cache (iflag=direct): a readback sees the card, and nothing evicts the rest of the cache
rd() { dd if=$D bs=512 skip=$1 count=$2 iflag=direct 2>/dev/null; }
u32() { od -An -tu4 -j$2 -N4 "$1" | tr -d ' '; }
# eGON checksum: sum of all 32-bit words with the checksum word read as 0x5F0A6C39 (busybox awk: %.0f, not %d)
egon_sum_ok() {
	[ "$(od -An -tu4 -v "$1" | awk '{for(i=1;i<=NF;i++){n++; v=(n==4)?1594518585:$i; s=(s+v)%4294967296}} END{printf "%.0f", s}')" = "$(u32 "$1" 12)" ]
}
# our SPL and nothing else: eGON + "SPL", declared length = file size, <= 48 KiB, good checksum, our hand-off inside
valid_ours() {
	[ -f "$1" ] || return 1
	[ "$(dd if="$1" bs=1 skip=4 count=8 2>/dev/null)" = eGON.BT0 ] || return 1
	[ "$(dd if="$1" bs=1 skip=20 count=3 2>/dev/null)" = SPL ] || return 1
	n=$(u32 "$1" 16); sz=$(wc -c < "$1")
	[ "$n" = "$sz" ] && [ "$n" -le $((STORE_N * 512)) ] && [ $((n % 512)) = 0 ] || return 1
	egon_sum_ok "$1" || return 1
	# NULs to newlines first: busybox grep -a compares line by line with strstr, and a NUL before the string on its
	# "line" hides it (it never found the hand-off in any build, 2026-11-06; bin/suspend runs busybox grep)
	LC_ALL=C tr '\000' '\n' < "$1" | grep -q -F "zero: vendor hand-off"
}
valid_stock() {
	[ "$(dd if="$1" bs=1 skip=4 count=8 2>/dev/null)" = eGON.BT0 ] || return 1
	[ "$(dd if="$1" bs=1 skip=20 count=3 2>/dev/null)" != SPL ] || return 1
	[ "$(u32 "$1" 16)" = 65536 ] && [ "$(wc -c < "$1")" = 65536 ] && egon_sum_ok "$1"
}
stored() { # the stored SPL, at its declared length, in /tmp/b0-ours.bin
	rd $STORE 1 > /tmp/b0-h.bin; n=$(u32 /tmp/b0-h.bin 16)
	case "$n" in ''|*[!0-9]*) return 1 ;; esac
	[ "$n" -gt 0 ] && [ "$n" -le $((STORE_N * 512)) ] && [ $((n % 512)) = 0 ] || return 1
	rd $STORE $((n / 512)) > /tmp/b0-ours.bin
	valid_ours /tmp/b0-ours.bin
}
slot_is() { [ "$(rd $SLOT $(($(wc -c < "$1") / 512)) | md5sum | cut -c1-32)" = "$(md5sum < "$1" | cut -c1-32)" ]; }
put() { # put <image>: body first, header sector last, then verify the whole image
	n=$(($(wc -c < "$1") / 512))
	dd if="$1" of=$D bs=512 skip=1 seek=$((SLOT + 1)) count=$((n - 1)) conv=notrunc,fsync 2>/dev/null || return 1
	dd if="$1" of=$D bs=512 count=1 seek=$SLOT conv=notrunc,fsync 2>/dev/null || return 1
	slot_is "$1"
}
case "$1" in
store)
	valid_ours "$2" || { echo "not a valid Zero SPL image: refusing"; exit 1; }
	dd if="$2" of=$D bs=512 seek=$STORE conv=notrunc,fsync 2>/dev/null
	stored && cmp -s /tmp/b0-ours.bin "$2" && echo stored ;;
stock)	# nonzero = this sleep is not safe: the suspend script then stays awake (Codex review: never sleep on an SPL)
	rd $SLOT 1 > /tmp/b0-slot.bin
	[ "$(wc -c < /tmp/b0-slot.bin)" = 512 ] || { echo "cannot read slot 16"; exit 1; }	# unknown is not safe
	[ "$(dd if=/tmp/b0-slot.bin bs=1 skip=20 count=3 2>/dev/null)" = SPL ] || exit 0	# stock boot0 in slot 16: it resumes
	rd $PIN 128 > /tmp/b0-stock.bin
	valid_stock /tmp/b0-stock.bin || { rd $PIN_B 128 > /tmp/b0-stock.bin; valid_stock /tmp/b0-stock.bin; } ||
		{ echo "no valid pinned stock boot0"; exit 1; }	# the second pinned copy too (code review)
	# ours comes back after the wake only when it is the stored copy; any other SPL is swapped out for good
	if stored && slot_is /tmp/b0-ours.bin; then
		: > $FLAG && sync && [ -f $FLAG ] || { echo "cannot record the swap"; exit 1; }
	fi
	put /tmp/b0-stock.bin ;;
ours|boot)
	[ -f $FLAG ] || exit 0			# this sleep did not swap: never put ours back
	# RTC GP14 nonzero = the loader's safety net has put stock back since the install (a failed attempt): a flag that
	# outlived that (a power cut before its removal was durable) must not bring the failed loader back (Codex review)
	if [ "$(busybox devmem 0x07000138)" != 0x00000000 ]; then
		rm -f $FLAG && sync
		echo "the loader's safety net restored stock since the install: not putting it back"; exit 0
	fi
	stored || exit 1
	slot_is /tmp/b0-ours.bin || put /tmp/b0-ours.bin || exit 1
	rm -f $FLAG && sync || exit 1 ;;
ack)
	# 15 min: a first boot that expands the card, a long card check or a MinUI.zip install all come before the first
	# frame; giving up early left the attempt unacknowledged and the next start put stock back (code review)
	_w=0; until [ -e /run/zero-menu-frame ]; do sleep 1; _w=$((_w + 1)); [ $_w -ge 900 ] && exit 0; done
	# proof this boot came through our SPL: its attempt marker (set after DRAM, just before the hand-off) and slot 16
	# holding the stored copy; the marker is cleared and read back before GP15, or the next start restores stock
	[ "$(rd 16640 1 | head -c 15)" = ZERO-ATTEMPT-V1 ] || exit 0
	stored && slot_is /tmp/b0-ours.bin || exit 0
	dd if=/dev/zero of=$D bs=512 seek=16640 count=1 conv=notrunc,fsync 2>/dev/null
	[ "$(rd 16640 1 | tr -d '\000' | wc -c)" = 0 ] || exit 1
	busybox devmem 0x0700013c 32 0 ;;
esac
