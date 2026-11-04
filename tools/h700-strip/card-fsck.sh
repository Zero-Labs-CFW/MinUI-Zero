#!/bin/sh
# Repair the card's filesystem before a MinUI.zip install, so an update never writes into a damaged FAT. startup.sh
# runs this BEFORE muOS mounts the card (beside expand-roms.sh): fsck has to run on an unmounted filesystem.
#
# Only on boots with a MinUI.zip on the card: a peek through a read-only mount decides, so a normal boot pays one
# mount and nothing else. Other CFW check the card the same way (ROCKNIX, Knulli, BaseOS, muOS), and ours needed it:
# fsck found 17 broken cluster chains on the H's card on 2026-11-02 (expand-roms.sh, which repairs once, at first
# boot). The result is left for card-update.sh, which runs once the card is mounted:
#   clean / repaired: install. repaired also moves fsck's FSCKnnnn.REC fragments out of the card root.
#   failed: do not install, keep the zip, say so.
#   no file: the check could not run (no fsck.vfat, not the boot card, mount refused). Install as before.
set -u

DEV=/dev/mmcblk0
PART="${DEV}p6"
PEEK=/tmp/zero-card-peek
STATE=${ZERO_FSCK_STATE:-/opt/minui-zero/card-fsck.state}   # rootfs: survives anything that remounts /tmp
LOG=/var/minui-zero-fsck.log

rm -f "$STATE" 2>/dev/null
command -v fsck.vfat >/dev/null 2>&1 || exit 0
[ -b "$PART" ] || exit 0
grep -q " /mnt/mmc " /proc/mounts && exit 0   # already mounted: wrong hook point, and fsck must not touch it
# the boot card, proven the way expand-roms.sh proves it: the running root must be mmcblk0p5 (TF2 is a second card)
ROOT_DEV=$(awk '$5 == "/" {d = $3} END {print d}' /proc/self/mountinfo 2>/dev/null)
[ -n "$ROOT_DEV" ] && [ "$ROOT_DEV" = "$(cat /sys/block/mmcblk0/mmcblk0p5/dev 2>/dev/null)" ] || exit 0

mkdir -p "$PEEK" 2>/dev/null
mount -t vfat -o ro "$PART" "$PEEK" 2>/dev/null || exit 0
_zip=0; [ -f "$PEEK/MinUI.zip" ] && _zip=1   # vfat lookups ignore case, like the frontend's check
# the release download as-is counts too (card-update.sh takes it as MinUI.zip)
for _z in "$PEEK"/[Mm][Ii][Nn][Uu][Ii]-[Zz][Ee][Rr][Oo]-*[Hh]700-*.[Zz][Ii][Pp]; do [ -f "$_z" ] && _zip=1 && break; done
# never hand the boot back with the peek still mounted: muOS mounts the same partition next (Codex review 2026-11-04).
# A plain [ -f ] holds nothing open, so a refusal is a fluke worth a retry; a lazy unmount is the last resort.
cd /
for _i in 1 2 3; do
	umount "$PEEK" 2>/dev/null
	grep -q " $PEEK " /proc/mounts || break
	sleep 1
done
if grep -q " $PEEK " /proc/mounts; then
	umount -l "$PEEK" 2>/dev/null
	# nothing further to try from here; say which way it went, for the log the frontend copies onto the card
	if grep -q " $PEEK " /proc/mounts; then
		echo "$(date '+%F %T') peek mount at $PEEK would not release, even lazily: muOS may fail to mount the card" >> "$LOG" 2>/dev/null
	else
		echo "$(date '+%F %T') peek mount would not release; lazily unmounted, no check this boot" >> "$LOG" 2>/dev/null
	fi
	exit 0
fi
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
