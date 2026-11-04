#!/bin/sh
# Repair the card's filesystem before a MinUI.zip install, so an update never writes into a damaged FAT. startup.sh
# runs this BEFORE muOS mounts the card (beside expand-roms.sh): fsck has to run on an unmounted filesystem.
#
# Only on boots with a MinUI.zip on the card: a look at the card's root directory decides, read straight off the
# partition (a few kilobytes, a few milliseconds), so a normal boot pays nothing. It used to mount the card
# read-only to look, which cost 0.66 s on EVERY boot (profiled on the H, 2026-11-04, boot-speed work). Other CFW check the card the same way (ROCKNIX, Knulli, BaseOS, muOS), and ours needed it:
# fsck found 17 broken cluster chains on the H's card on 2026-11-02 (expand-roms.sh, which repairs once, at first
# boot). The result is left for card-update.sh, which runs once the card is mounted:
#   clean / repaired: install. repaired also moves fsck's FSCKnnnn.REC fragments out of the card root.
#   failed: do not install, keep the zip, say so.
#   no file: the check could not run (no fsck.vfat, not the boot card, mount refused). Install as before.
set -u

DEV=/dev/mmcblk0
PART="${DEV}p6"
STATE=${ZERO_FSCK_STATE:-/opt/minui-zero/card-fsck.state}   # rootfs: survives anything that remounts /tmp
LOG=/var/minui-zero-fsck.log

rm -f "$STATE" 2>/dev/null
command -v fsck.vfat >/dev/null 2>&1 || exit 0
[ -b "$PART" ] || exit 0
grep -q " /mnt/mmc " /proc/mounts && exit 0   # already mounted: wrong hook point, and fsck must not touch it
# the boot card, proven the way expand-roms.sh proves it: the running root must be mmcblk0p5 (TF2 is a second card)
ROOT_DEV=$(awk '$5 == "/" {d = $3} END {print d}' /proc/self/mountinfo 2>/dev/null)
[ -n "$ROOT_DEV" ] && [ "$ROOT_DEV" = "$(cat /sys/block/mmcblk0/mmcblk0p5/dev 2>/dev/null)" ] || exit 0

# THE ROOT DIRECTORY, READ RAW (FAT32 only; the image and expand-roms.sh always make FAT32). Both names an update can
# have show up there as an 8.3 entry "MINUI???ZIP": MinUI.zip is "MINUI   ZIP", and a long name such as
# MinUI-Zero-anbernic-h700-v1.10.0-update.zip gets a short alias like "MINUI-~1ZIP" from any FAT driver. Deleted entries
# start with 0xE5 and long-name pieces are UTF-16, so neither can match. A false match only means one unneeded fsck;
# anything this cannot read (not FAT32, odd geometry) skips the check, as a refused mount did before.
# the boot sector once, into RAM: seven od runs on the raw card cost 0.15 s per boot, on a copy in /tmp nothing
BS=/tmp/zero-card-bs
dd if="$PART" of="$BS" bs=512 count=1 2>/dev/null || exit 0
rd() { od -An -tu"$2" -j"$1" -N"$2" "$BS" 2>/dev/null | tr -d ' '; }   # little-endian fields, little-endian CPU
num() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; }
_bps=$(rd 11 2); _spc=$(rd 13 1); _res=$(rd 14 2); _nfat=$(rd 16 1); _f16=$(rd 22 2); _fsz=$(rd 36 4); _clu=$(rd 44 4)
for _v in "$_bps" "$_spc" "$_res" "$_nfat" "$_f16" "$_fsz" "$_clu"; do num "$_v" || exit 0; done
[ "$_f16" -eq 0 ] && [ "$_bps" -ge 512 ] && [ "$_bps" -le 4096 ] && [ "$_spc" -ge 1 ] && [ "$_clu" -ge 2 ] || exit 0
_zip=0; _n=0
# follow the root directory's cluster chain through the first FAT to its end (Codex review 2026-11-04: a root can
# legally span many clusters). A card root is a few dozen entries, a cluster or two; 256 clusters is megabytes of
# entries, so a chain that long, or one that points back at itself, is a loop in a damaged FAT: check the card then,
# within a fraction of a second, rather than walk the loop (Codex review round 2).
_max=$(( _fsz * _bps / 4 )); [ "$_max" -gt 256 ] && _max=256
while [ "$_clu" -ge 2 ] && [ "$_clu" -lt 268435448 ]; do
	[ "$_n" -lt "$_max" ] || { _zip=1; break; }
	_sec=$(( _res + _nfat * _fsz + (_clu - 2) * _spc ))
	if dd if="$PART" bs="$_bps" skip="$_sec" count="$_spc" 2>/dev/null | tr '\000-\037\177-\377' '\n' | grep -q 'MINUI...ZIP'; then
		_zip=1; break
	fi
	_prev=$_clu
	_clu=$(od -An -tu4 -j$(( _res * _bps + _clu * 4 )) -N4 "$PART" 2>/dev/null | tr -d ' ')
	num "$_clu" || break
	_clu=$(( _clu & 268435455 )); _n=$((_n + 1))
	[ "$_clu" != "$_prev" ] || { _zip=1; break; }
done
rm -f "$BS"
[ $_zip = 1 ] || exit 0

# a big card takes a while: show "Updating" (fb0 is live before the card mounts). The frame must be the one for this
# board's panel page (the build renders one per page and maps every board to it), read by the board muOS was set up
# as; a board not in the map gets no frame rather than another panel's, which draws garbage.
_b=$(cat /opt/muos/device/config/board/name 2>/dev/null)
_f=$(awk -v b="$_b" '$1 == b || $1 == "rg35xx-" b { print $2; exit }' /opt/minui-zero/splash/map 2>/dev/null)
_shown=
if [ -n "$_f" ] && [ -f "/opt/minui-zero/splash/$_f" ] && [ -c /dev/fb0 ]; then
	echo 0 > /sys/class/graphics/fb0/blank 2>/dev/null
	cat "/opt/minui-zero/splash/$_f" > /dev/fb0 2>/dev/null && _shown=1
fi
echo "$(date '+%F %T') MinUI.zip found: checking $PART" >> "$LOG" 2>/dev/null
# -a repairs without asking and truncates only what is already unreadable: 0 = clean, 1 = repaired, else failed
fsck.vfat -a "$PART" >> "$LOG" 2>&1; _rc=$?
case $_rc in 0) _r=clean ;; 1) _r=repaired ;; *) _r=failed ;; esac
echo "$(date '+%F %T') fsck.vfat exit $_rc: $_r" >> "$LOG" 2>/dev/null
# line 2 tells card-update.sh the frame is up, so it does not draw a second "Updating" screen over it
{ echo "$_r"; [ -z "$_shown" ] || echo shown; } > "$STATE"
sync
exit 0
