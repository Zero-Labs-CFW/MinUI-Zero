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
	sync; reboot; exit 0 # a mounted card must never be shared; restarting is the safe way back
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
echo "usb-drive: unshared $(cat /proc/uptime) seen=$seen"

# 4) check the card the way stock does, keep this log on it, restart
[ -f /usr/trimui/apps/usb_storage/bg_checking.png ] && pic2fb /usr/trimui/apps/usb_storage/bg_checking.png 2>/dev/null
umount "$CARD"
if [ "$FS" = exfat ]; then fsck.exfat -y "$DEV"; else fsck.fat -a "$DEV"; fi
echo "usb-drive: fsck rc=$? $(cat /proc/uptime)"
if [ -n "$LABEL" ]; then
	if [ "$FS" = exfat ]; then exfatlabel "$DEV" "$LABEL" >/dev/null 2>&1; else [ "$(fatlabel "$DEV" 2>/dev/null)" = "$LABEL" ] || fatlabel "$DEV" "$LABEL"; fi
	echo "usb-drive: label now [$(fatlabel "$DEV" 2>/dev/null)]"
fi
if mount "$DEV" "$CARD" 2>/dev/null; then
	mkdir -p "$CARD/.userdata/tg5040/logs" && cp /tmp/usb-drive.log "$CARD/.userdata/tg5040/logs/USB Drive.txt"
	sync; umount "$CARD"
fi
rm -f /tmp/stay_awake
sync
reboot
