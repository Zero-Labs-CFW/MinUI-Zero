#!/bin/sh
# USB Drive, phase 2 (File Transfer.pak). Runs from RAM: launch.sh copied this script, say.elf, its
# library and the UI art to /tmp/usb-drive and exec'd here with every fd off the card. Recipe from
# TrimUI's stock usb_storage app and CrossMix's usb_storage/launch.sh: free the card, unmount it,
# share it with setusbconfig, then check it and restart. Never shares a card that is still mounted.
T=/tmp/usb-drive
CARD=/mnt/SDCARD
SYS=$CARD/.system/tg5040
cd /
echo 1 > /tmp/stay_awake
# every way out restarts; keep this run's log on INTERNAL storage first (the card may be unsafe to touch)
finish() { cp /tmp/usb-drive.log /mnt/UDISK/usb-drive-last.log 2>/dev/null; sync; reboot; exit 0; }
# The firmware automounts the card on block hotplug events (/etc/hotplug.d/block/10-mount, fstools
# `block hotplug`), and closing a device that was written raises one: the gadget letting go and fsck
# finishing each remounted the card behind this script, once mid-teardown (found on-device 2026-10-05).
# Mask the hook for this run only; the restart at the end brings it back.
: > "$T/no-hotplug" && mount --bind "$T/no-hotplug" /etc/hotplug.d/block/10-mount
# ...and fail CLOSED: without the mask the card can be remounted under fsck or while the computer owns it.
# Nothing has been touched yet, so going back to the menu is safe (Codex review, 2026-10-05).
if ! grep -q " /etc/hotplug.d/block/10-mount " /proc/mounts; then
	echo "usb-drive: could not mask the automount hook, not starting"
	rm -f /tmp/stay_awake
	"$T/bin/say.elf" "USB Drive couldn't start.

Nothing was changed."
	exit 0
fi
echo "usb-drive: start $(cat /proc/uptime)"

# 1) whatever could relaunch something from the card goes first, then everything still holding it
for pat in S99runtrimui runtrimui "MinUI.pak/launch.sh"; do
	for p in $(pgrep -f "$pat" 2>/dev/null); do [ "$p" = "$$" ] || kill -9 "$p" 2>/dev/null; done
done
# Three commands over all of /proc, not two per process: the per-process loop took 4 s a pass (141
# processes on a Brick) and the whole start took 11.6 s (Dan: "took a while to turn on").
holders() {
	{
		grep -l "$CARD" /proc/[0-9]*/maps 2>/dev/null | cut -d/ -f3
		ls -l /proc/[0-9]*/cwd /proc/[0-9]*/exe 2>/dev/null | grep -F "$CARD" | sed 's#.*/proc/\([0-9][0-9]*\)/.*#\1#'
		ls -l /proc/[0-9]*/fd 2>/dev/null | awk -v c="$CARD" '/^\/proc\/[0-9]+\/fd:$/ { split($0, a, "/"); pid = a[3]; next } index($0, c) { print pid }'
	} | sort -u | grep -vx "$$"
}
H=$(holders)
for p in $H; do echo "usb-drive: TERM $p $(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null | cut -c1-80)"; kill -TERM "$p" 2>/dev/null; done
usleep 500000
for p in $H $(holders); do kill -0 "$p" 2>/dev/null && { echo "usb-drive: KILL $p"; kill -KILL "$p" 2>/dev/null; }; done
usleep 200000
sync
DEV=/dev/mmcblk1p1; [ -b "$DEV" ] || DEV=/dev/mmcblk1
# fsck.fat -a drops a label that lives only in the boot sector (both of Dan's cards lost theirs:
# BRICKPRO, ZEROTEST); read it now and put it back properly afterwards
case "$(blkid "$DEV" 2>/dev/null)" in *exfat*) FS=exfat;; *) FS=vfat;; esac
if [ "$FS" = exfat ]; then LABEL=$(exfatlabel "$DEV" 2>/dev/null | tail -1 | sed 's/^[^:]*: *//'); else LABEL=$(fatlabel "$DEV" 2>/dev/null); fi
echo "usb-drive: $FS label=[$LABEL] $(cat /proc/uptime)"
if ! umount "$CARD"; then
	echo "usb-drive: umount failed, holders: $(holders | tr '\n' ' ')"
	finish # a mounted card must never be shared; restarting is the safe way back
fi
# ...and not mounted ANYWHERE: a bind mount or another partition elsewhere would still be live while the
# computer writes the disk (Codex review, 2026-10-05). The tmpfs below is not a card mount.
if grep -q "^/dev/mmcblk1" /proc/mounts; then
	echo "usb-drive: card still mounted: $(grep "^/dev/mmcblk1" /proc/mounts | tr '\n' ' ')"
	finish
fi

# 2) the UI runs from a RAM copy at the same paths it was built for (RES_PATH etc. are compile-time)
mount -t tmpfs -o size=16m tmpfs "$CARD"
mkdir -p "$SYS/bin" "$SYS/lib" "$CARD/.system/res"
cp "$T/bin/"* "$SYS/bin/"; cp "$T/lib/"* "$SYS/lib/"; cp -R "$T/res/." "$CARD/.system/res/"

# 3) share it (setusbconfig mass_storage exports /dev/mmcblk1, the whole card)
[ -x /usr/trimui/bin/usb_device.sh ] && /usr/trimui/bin/usb_device.sh
/bin/setusbconfig mass_storage
echo "usb-drive: shared $(cat /proc/uptime)"
"$SYS/bin/say.elf" "USB Drive is on

Copy your files on the computer.
When you're done, eject the drive
there, then unplug or press A here." &
SAY=$!
seen=0
while kill -0 "$SAY" 2>/dev/null; do
	st=$(cat /sys/class/udc/*/state 2>/dev/null)
	[ "$st" = "configured" ] && seen=1
	if [ "$seen" = 1 ] && [ "$st" = "not attached" ]; then echo "usb-drive: unplugged"; break; fi
	sleep 1
done
kill -9 "$SAY" 2>/dev/null # -9: SDL turns SIGTERM into a quit event say.elf never reads (found on-device)
/bin/setusbconfig none
# confirm the computer has lost the card BEFORE anything here writes it: stock "none" only unlinks the
# function and is not checked. Drop the backing file too; if either is still there, restart without
# the check rather than fsck a disk the computer may still be writing (Codex review, 2026-10-05).
G=/sys/kernel/config/usb_gadget/g1
LUN=$G/functions/mass_storage.usb0/lun.0
echo "" > "$LUN/file" 2>/dev/null
if [ -e "$G/configs/c.1/f1" ] || [ -n "$(cat "$LUN/file" 2>/dev/null)" ]; then
	echo "usb-drive: still exported (lun=[$(cat "$LUN/file" 2>/dev/null)]), restarting without the check"
	finish
fi
echo "usb-drive: unshared $(cat /proc/uptime) seen=$seen"

# 4) check the card the way stock does, keep this log on it, restart
[ -f /usr/trimui/apps/usb_storage/bg_checking.png ] && pic2fb /usr/trimui/apps/usb_storage/bg_checking.png 2>/dev/null
umount "$CARD" || echo "usb-drive: tmpfs umount failed: $(grep " $CARD " /proc/mounts)"
# fsck only an unmounted card: drop any mount that still slipped in, and skip the check if one stays
for m in $(grep "^/dev/mmcblk1" /proc/mounts | cut -d' ' -f2); do echo "usb-drive: unexpected mount at $m"; umount "$m"; done
if grep -q "^/dev/mmcblk1" /proc/mounts; then
	echo "usb-drive: card still mounted, skipping the check"
else
	if [ "$FS" = exfat ]; then fsck.exfat -y "$DEV"; else fsck.fat -a "$DEV"; fi
	echo "usb-drive: fsck rc=$? $(cat /proc/uptime)"
fi
if [ -n "$LABEL" ]; then
	if [ "$FS" = exfat ]; then exfatlabel "$DEV" "$LABEL" >/dev/null 2>&1; else [ "$(fatlabel "$DEV" 2>/dev/null)" = "$LABEL" ] || fatlabel "$DEV" "$LABEL"; fi
	echo "usb-drive: label now [$(fatlabel "$DEV" 2>/dev/null)]"
fi
if mount "$DEV" "$CARD"; then
	echo "usb-drive: card back $(cat /proc/uptime)"
	# fsck -a always saves orphaned chains as FSCK0000.REC... in the card root (no flag frees them instead),
	# and they landed in Finder (Dan: "what is all these .rec files?"). They are pieces of writes a power cut
	# interrupted, not usable files: kept, but moved out of sight into a dated folder.
	R="$CARD/.userdata/fsck-recovered/$(date +%Y%m%d-%H%M%S)-$$" # -$$: two runs in one second never share a folder
	for f in "$CARD"/FSCK[0-9][0-9][0-9][0-9].REC; do
		[ -f "$f" ] || continue
		mkdir -p "$R" && mv "$f" "$R/" && echo "usb-drive: moved $(basename "$f") to ${R#$CARD/}"
	done
	mkdir -p "$CARD/.userdata/tg5040/logs" && cp /tmp/usb-drive.log "$CARD/.userdata/tg5040/logs/USB Drive.txt"
	sync; umount "$CARD"
else
	echo "usb-drive: remount failed: $(grep " $CARD " /proc/mounts)"
fi
rm -f /tmp/stay_awake
echo "usb-drive: done $(cat /proc/uptime)"
finish
