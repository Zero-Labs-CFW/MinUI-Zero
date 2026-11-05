#!/bin/sh
# MENU FIRST (boot speed, 2026-11-04). inittab runs this right after it remounts / read-write, before any muOS init:
# the card is checked and mounted and our frontend starts here, while muOS's sysinit (udev, its startup.sh: modules,
# the codec, brightness, WiFi plumbing) runs alongside. The menu needs only the card; the frontend waits for the GPU
# module and the codec before it launches a game (minui-frontend.sh, wait_for_system). startup.sh skips what this did
# and starts no second frontend (it checks /run/zero-early).
# Everything here is the same work startup.sh did, in the same order, just earlier: expand-roms.sh and card-fsck.sh
# before the mount (both need the card unmounted), the mount with storage.sh's options.
read -r _zu _ </proc/uptime; echo "$_zu early" >>/dev/shm/zero-boot
mkdir -p /tmp/muos /run/muos /run/zero-bb
# BUSYBOX FIRST for what early boot runs (boot speed, 2026-11-05): grep is GNU grep and insmod is kmod here, each pulling
# its own libraries and glibc off the card cold (measured 1.5 MB and 2.4 MB of reads on the Plus); busybox is already in
# the page cache (it is init). Everything started below, the frontend included, inherits this PATH. mount is NOT
# swapped: expand-roms.sh mounts with nofail, which busybox mount would hand to vfat as an unknown option.
for _a in grep insmod; do ln -sf /bin/busybox "/run/zero-bb/$_a"; done
export PATH="/run/zero-bb:$PATH"
# LATE CONTROLLERS: the boot package marks some controllers "late" so the kernel skips them at start-up; a module loaded
# here starts them. Each load is guarded by a marker written (and synced) before insmod and removed after it: a boot that
# dies while loading leaves the marker, and the next boot skips that module once (removing the marker), so a module that
# crashes a board still lets every other boot reach the menu, and a marker stranded by a power cut costs one boot of
# that hardware, never more (Codex review 2026-11-04).
late_load() { # <module> <marker name> <log tag>
	[ -f "$1" ] || return 0
	if [ -e "/opt/minui-zero/$2" ]; then
		rm -f "/opt/minui-zero/$2"
		echo "$3: skipped this boot, the last one died while loading it" >/dev/kmsg
		return 0
	fi
	# only the marker is made durable (fsync of that one file): a global sync here flushed everything in flight on
	# the card in the menu's window (code review); a removal lost to a power cut costs one boot of that hardware
	dd if=/dev/null of="/opt/minui-zero/$2" conv=fsync 2>/dev/null
	insmod "$1" 2>/dev/kmsg
	rm -f "/opt/minui-zero/$2"
}
# The second card slot and WiFi (zero_late_mmc.ko), at once and in the background: their probes only sleep, and muOS's
# WiFi load and second card mount come later in its startup (mount-fast.awk waits for the slot).
late_load /opt/minui-zero/zero_late_mmc.ko late-mmc-trying late-mmc </dev/null >/dev/null 2>&1 &
[ -x /opt/minui-zero/expand-roms.sh ] && /opt/minui-zero/expand-roms.sh
[ -x /opt/minui-zero/card-fsck.sh ] && /opt/minui-zero/card-fsck.sh
mkdir -p /mnt/mmc
grep -q " /mnt/mmc " /proc/mounts || busybox mount -t vfat -o rw,utf8,noatime /dev/mmcblk0p6 /mnt/mmc 2>/dev/null || exit 0
read -r _zu _ </proc/uptime; echo "$_zu mounted" >>/dev/shm/zero-boot
: >/run/zero-early
read -r _zu _ </proc/uptime; echo "$_zu frontend" >>/dev/shm/zero-boot
cd /
setsid sh /opt/minui-zero/minui-frontend.sh </dev/null >/dev/null 2>&1 &
# USB host (zero_late_usb.ko), 3 s after the menu starts.
( sleep 3; late_load /opt/minui-zero/zero_late_usb.ko late-usb-trying late-usb ) </dev/null >/dev/null 2>&1 &
exit 0
