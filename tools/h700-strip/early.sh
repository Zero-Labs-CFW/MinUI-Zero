#!/bin/sh
# MENU FIRST (boot speed, 2026-11-04). inittab runs this right after it remounts / read-write, before any muOS init:
# the card is checked and mounted and our frontend starts here, while muOS's sysinit (udev, its startup.sh: modules,
# the codec, brightness, WiFi plumbing) runs alongside. The menu needs only the card; the frontend waits for the GPU
# module and the codec before it launches a game (minui-frontend.sh, wait_for_system). startup.sh skips what this did
# and starts no second frontend (it checks /run/zero-early).
# Everything here is the same work startup.sh did, in the same order, just earlier: expand-roms.sh and card-fsck.sh
# before the mount (both need the card unmounted), the mount with storage.sh's options.
read -r _zu _ </proc/uptime; echo "$_zu early" >>/dev/shm/zero-boot
mkdir -p /tmp/muos /run/muos
# The codec state, restored now in the background so it is done (and alsa-lib is in the page cache) by the time the
# frontend's own blocking restore runs before minui starts: that one took 0.23 s on the H cold and ~0 warm.
alsactl -U -f /opt/muos/device/control/asound.state restore </dev/null >/dev/null 2>&1 &
[ -x /opt/minui-zero/expand-roms.sh ] && /opt/minui-zero/expand-roms.sh
[ -x /opt/minui-zero/card-fsck.sh ] && /opt/minui-zero/card-fsck.sh
mkdir -p /mnt/mmc
grep -q " /mnt/mmc " /proc/mounts || mount -t vfat -o rw,utf8,noatime,nofail /dev/mmcblk0p6 /mnt/mmc 2>/dev/null || exit 0
read -r _zu _ </proc/uptime; echo "$_zu mounted" >>/dev/shm/zero-boot
: >/run/zero-early
read -r _zu _ </proc/uptime; echo "$_zu frontend" >>/dev/shm/zero-boot
cd /
setsid sh /opt/minui-zero/minui-frontend.sh </dev/null >/dev/null 2>&1 &
# USB host, started after the menu instead of during the kernel's start-up (zero_late_usb.ko: the boot package marks the
# controllers "late"). Guarded like the card frontend's tries: the marker is written before the load and removed after
# it, so a boot that dies while loading it leaves the marker, and every boot after skips the module (USB host stays off,
# the handheld boots) until an update replaces it, which clears the marker.
L=/opt/minui-zero/zero_late_usb.ko
if [ -f "$L" ]; then
	(
		sleep 3
		if [ -e /opt/minui-zero/late-usb-trying ]; then
			echo "late-usb: skipped, a boot died while loading it" >/dev/kmsg
		else
			: >/opt/minui-zero/late-usb-trying; sync
			insmod "$L" 2>/dev/kmsg
			rm -f /opt/minui-zero/late-usb-trying; sync
		fi
	) </dev/null >/dev/null 2>&1 &
fi
exit 0
