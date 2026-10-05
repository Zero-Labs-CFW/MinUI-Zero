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
holders() {
	for d in /proc/[0-9]*; do
		p=${d#/proc/}
		[ "$p" = "$$" ] && continue
		if ls -l "$d/cwd" "$d/exe" "$d/fd" 2>/dev/null | grep -q "$CARD" || grep -q "$CARD" "$d/maps" 2>/dev/null; then echo "$p"; fi
	done
}
for sig in TERM KILL; do
	for p in $(holders); do echo "usb-drive: $sig $p $(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null | cut -c1-80)"; kill -$sig "$p" 2>/dev/null; done
	sleep 1
done
sync
DEV=/dev/mmcblk1p1; [ -b "$DEV" ] || DEV=/dev/mmcblk1
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
case "$(blkid "$DEV" 2>/dev/null)" in
	*exfat*) fsck.exfat -y "$DEV" ;;
	*) fsck.fat -a "$DEV" ;;
esac
echo "usb-drive: fsck rc=$? $(cat /proc/uptime)"
if mount "$DEV" "$CARD" 2>/dev/null; then
	mkdir -p "$CARD/.userdata/tg5040/logs" && cp /tmp/usb-drive.log "$CARD/.userdata/tg5040/logs/USB Drive.txt"
	sync; umount "$CARD"
fi
rm -f /tmp/stay_awake
sync
reboot
