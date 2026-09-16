#!/bin/sh
# One-shot ROMS expansion for the MinUI Zero h700 image. Runs from startup.sh BEFORE muOS mounts
# the card, because parted refuses to resize a partition that is in use.
#
# The flashed image is ~1.4GB, so on a bigger card everything past the ROMS partition is
# unreachable. Measured on-device 2026-08-10 (sysfs, 32GB card): disk 61071360 sectors, ROMS starts
# at 2416640 and is 524288 long, leaving 58130432 sectors (27.7GiB) stranded.
#
# There is no in-place FAT32 grow here (parted, sfdisk, mkfs.vfat, partx are present; fatresize and
# resize2fs are not), so this does what muOS's own factory reset does: resize the partition,
# reformat, restore. It restores OUR payload from a verified copy instead of an archive.
#
# HISTORY, so the traps stay fixed (2026-08-10):
#   1. v1 ran after the card was mounted and used `umount -l`. /proc/mounts looked clean while the
#      filesystem was still busy, so parted only printed "Partition is being used ... Yes/No?" and
#      did nothing. mkfs then reformatted at the OLD size and the script reported success because it
#      never measured the result. No data was lost, but nothing was gained either.
#   2. v2 fixed the timing but split the work across a forced reboot, which introduced worse
#      failures: an interrupted second phase would overwrite the good backup with a half-restored
#      card, and a power cut in one specific window disabled expansion permanently.
# So: one uninterrupted pass, `partx -u` to refresh the kernel view instead of rebooting, an ATTEMPT
# marker that is never retried automatically, and success only when the result is measured.
set -u

DEV=/dev/mmcblk0
PART_NUM=6
PART="${DEV}p${PART_NUM}"
SYSFS=/sys/block/mmcblk0/mmcblk0p6
MOUNT=/mnt/mmc
STATE=/opt/minui-zero
DONE_MARK="$STATE/roms-expanded"
ATTEMPT_MARK="$STATE/roms-expanding"
FAILED_MARK="$STATE/roms-expand-failed"
BACKUP=/var/minui-zero-payload
LOG=/var/minui-zero-expand.log        # rootfs: the card is not mounted while this runs. The
                                      # frontend copies this onto the card once it is mounted, so
                                      # the user can read it without ssh.
MIN_GAIN_SECTORS=2097152              # 1GiB; below this a destructive reformat is not worth it

say() { echo "$(date +%H:%M:%S) $*" >> "$LOG" 2>/dev/null; }
give_up() { say "$1"; touch "$FAILED_MARK" 2>/dev/null; sync; exit 0; }

[ -f "$DONE_MARK" ] && exit 0
[ -f "$FAILED_MARK" ] && exit 0
# An attempt marker means a previous run stopped somewhere between the format and a verified
# restore. Never retry that automatically: the backup on the rootfs may be the only complete copy
# of the payload, and a blind retry would overwrite it with whatever is on the card now.
[ -f "$ATTEMPT_MARK" ] && {
	say "a previous attempt did not finish. Not retrying. The payload copy (if any) is at $BACKUP"
	touch "$FAILED_MARK" 2>/dev/null; sync; exit 0
}

for t in parted mkfs.vfat partx fdisk du df find cp; do
	command -v "$t" >/dev/null 2>&1 || { say "missing tool: $t. Skipping."; exit 0; }
done
[ -b "$PART" ] || { say "no $PART. Skipping."; exit 0; }
grep -q " $MOUNT " /proc/mounts && { say "card already mounted: wrong hook point. Skipping."; exit 0; }

DISK_SECTORS=$(cat /sys/block/mmcblk0/size 2>/dev/null)
PART_START=$(cat "$SYSFS/start" 2>/dev/null)
PART_SIZE=$(cat "$SYSFS/size" 2>/dev/null)
case "${DISK_SECTORS:-x}${PART_START:-x}${PART_SIZE:-x}" in *x*) say "cannot read geometry. Skipping."; exit 0 ;; esac
[ "$DISK_SECTORS" -gt 0 ] && [ "$PART_SIZE" -gt 0 ] && [ "$PART_START" -gt 0 ] || { say "implausible geometry. Skipping."; exit 0; }
FREE=$(( DISK_SECTORS - PART_START - PART_SIZE ))
if [ "$FREE" -le "$MIN_GAIN_SECTORS" ]; then
	# Nothing worth reclaiming. Deliberately NO done-marker: this is cheap to re-evaluate, and
	# writing one here is how v2 could permanently disable expansion after an interrupted resize.
	exit 0
fi

say "start: disk=${DISK_SECTORS}s part=${PART_START}+${PART_SIZE}s free=${FREE}s (~$(( FREE / 2048 ))MB)"

# Tell the user: the copy-format-copy below takes minutes on a big card with only the boot logo
# on screen (Dan, 2026-09-16). A pre-rendered panel-sized XRGB frame (make-splash.py at build
# time) written straight to fb0, which is live before the card mounts. Page 0 is what is shown.
SPLASH=/opt/minui-zero/installing.raw
if [ -f "$SPLASH" ] && [ -c /dev/fb0 ]; then
	echo 0 > /sys/class/graphics/fb0/blank 2>/dev/null
	cat "$SPLASH" > /dev/fb0 2>/dev/null
	say "splash shown"
fi

# ---- 1. copy the payload off the card and verify it, before anything destructive ----
mkdir -p "$MOUNT" 2>/dev/null
mount -t vfat -o rw,utf8,noatime,nofail "$PART" "$MOUNT" 2>>"$LOG" || { say "cannot mount the card to back it up. Skipping."; exit 0; }
PAYLOAD_KB=$(du -sk "$MOUNT" 2>/dev/null | cut -f1)
# Measure the filesystem that actually holds the backup, not "/" (they can differ).
mkdir -p "$(dirname "$BACKUP")" 2>/dev/null
BK_FS=$(df -k "$(dirname "$BACKUP")" 2>/dev/null | awk 'NR==2 {print $1}')
BK_FREE_KB=$(df -k "$(dirname "$BACKUP")" 2>/dev/null | awk 'NR==2 {print $4}')
case "$BK_FS" in
	tmpfs|none|"") umount "$MOUNT" 2>/dev/null; say "backup target is $BK_FS (volatile). Skipping."; exit 0 ;;
esac
case "${PAYLOAD_KB:-x}${BK_FREE_KB:-x}" in *x*) umount "$MOUNT" 2>/dev/null; say "cannot size payload/backup fs. Skipping."; exit 0 ;; esac
if [ "$BK_FREE_KB" -lt $(( PAYLOAD_KB * 2 + 65536 )) ]; then
	umount "$MOUNT" 2>/dev/null
	say "payload ${PAYLOAD_KB}KB does not fit safely in ${BK_FREE_KB}KB on $BK_FS. Skipping."
	exit 0
fi
rm -rf "$BACKUP" 2>/dev/null
mkdir -p "$BACKUP" 2>/dev/null || { umount "$MOUNT" 2>/dev/null; say "cannot create $BACKUP. Skipping."; exit 0; }
cp -a "$MOUNT"/. "$BACKUP"/ 2>>"$LOG" || { rm -rf "$BACKUP"; umount "$MOUNT" 2>/dev/null; say "backup copy failed. Card untouched."; exit 0; }
SRC=$(find "$MOUNT" | wc -l); BAK=$(find "$BACKUP" | wc -l)
[ "$SRC" = "$BAK" ] || { rm -rf "$BACKUP"; umount "$MOUNT" 2>/dev/null; say "backup verify failed ($SRC vs $BAK). Card untouched."; exit 0; }
sync
say "payload copied and verified: $BAK entries, ${PAYLOAD_KB}KB on $BK_FS"

# ---- 2. release the card for real. A lazy unmount is what defeated v1, so insist on a clean one ----
cd /                                   # no process cwd may pin the mountpoint
umount "$MOUNT" 2>>"$LOG" || { rm -rf "$BACKUP"; say "clean unmount refused. Card untouched."; exit 0; }
grep -q " $MOUNT " /proc/mounts && { rm -rf "$BACKUP"; say "still mounted after umount. Card untouched."; exit 0; }

# ---- 3. grow the partition. Still non-destructive to the filesystem inside it ----
printf "w\nw\n" | fdisk "$DEV" >> "$LOG" 2>&1     # rewrite the table so the backup GPT sits at the true disk end
printf "Yes\n" | parted ---pretend-input-tty "$DEV" resizepart "$PART_NUM" 100% >> "$LOG" 2>&1
parted ---pretend-input-tty "$DEV" set "$PART_NUM" boot off    >> "$LOG" 2>&1
parted ---pretend-input-tty "$DEV" set "$PART_NUM" hidden off  >> "$LOG" 2>&1
parted ---pretend-input-tty "$DEV" set "$PART_NUM" msftdata on >> "$LOG" 2>&1
sync
partx -u --nr "$PART_NUM" "$DEV" >> "$LOG" 2>&1 || partprobe "$DEV" >> "$LOG" 2>&1
sleep 1
NEW_SIZE=$(cat "$SYSFS/size" 2>/dev/null || echo 0)
if [ "$NEW_SIZE" -le "$PART_SIZE" ]; then
	# Nothing has been formatted yet, so this is a clean stop. The filesystem is untouched and the
	# card will mount normally; at worst the table now describes a larger partition, which is safe.
	rm -rf "$BACKUP"
	say "kernel still reports ${NEW_SIZE}s (was ${PART_SIZE}s). No format attempted. Card is fine."
	exit 0
fi
say "partition grew: kernel now reports ${NEW_SIZE}s (~$(( NEW_SIZE / 2048 ))MB)"

# ---- 4. the destructive step. From here a failure needs a human, so mark the attempt first ----
touch "$ATTEMPT_MARK"; sync
mkfs.vfat -F 32 -n ZERO "$PART" >> "$LOG" 2>&1 || give_up "mkfs.vfat failed. Payload is safe at $BACKUP"
sync
mount -t vfat -o rw,utf8,noatime,nofail "$PART" "$MOUNT" 2>>"$LOG" || give_up "remount after format failed. Payload is safe at $BACKUP"
cp -a "$BACKUP"/. "$MOUNT"/ 2>>"$LOG" || give_up "restore failed. Payload is safe at $BACKUP"
NEW=$(find "$MOUNT" | wc -l)
sync
[ "$NEW" = "$BAK" ] || give_up "restore verify mismatch ($NEW vs $BAK). Payload is safe at $BACKUP"

# ---- 5. success is a measurement, not an assumption ----
SIZE_KB=$(df -k "$MOUNT" 2>/dev/null | awk 'NR==2 {print $2}')
if [ -z "$SIZE_KB" ] || [ "$SIZE_KB" -le $(( PART_SIZE / 2 )) ]; then
	give_up "filesystem did not grow (${SIZE_KB}KB). Payload restored and safe at $BACKUP"
fi
umount "$MOUNT" 2>>"$LOG" || say "note: could not unmount after restore; muOS will mount over it"
rm -f "$ATTEMPT_MARK"
touch "$DONE_MARK"
rm -rf "$BACKUP"
sync
say "done: ROMS is now $(( SIZE_KB / 1024 ))MB with $NEW entries restored"
exit 0
