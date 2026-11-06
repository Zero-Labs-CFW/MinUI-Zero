#!/bin/sh
# What the stock initramfs did, for boards that now boot without one (boot speed, 2026-11-04). inittab runs this
# while / is still read-only, just before it remounts / read-write. The image's own first boots (the stock Plus files,
# until a model is picked) still have the initramfs, which mounted / read-write already: then this does nothing but
# the watchdog step.
#
# 1. The root filesystem, checked only when it needs it. The stock initramfs ran e2fsck -y on every boot; without it
#    the kernel mounts root itself and replays the ext4 journal, which covers a power cut. What the journal cannot fix
#    the kernel counts in errors_count, and only then does e2fsck run (the idea is BaseOS's, docs/12-kernel-gzip.md).
#    e2fsck and its libraries come from the stock initramfs, in this folder. Never on a writable root (Codex review
#    2026-11-04): e2fsck refuses a mounted rw filesystem, and must. A repair restarts: the kernel may still cache what
#    e2fsck just changed on disk.
# 2. The RG34XX H's stock initramfs, alone of the eleven, started busybox's watchdog on /dev/watchdog0 (Codex review
#    2026-11-04). Keep doing that on that board, so it boots the way its own firmware expects.
case "$(cat /opt/muos/device/config/board/name 2>/dev/null)" in
	rg34xx-h) [ -c /dev/watchdog0 ] && watchdog -t 5 /dev/watchdog0 ;;
esac

awk '$2 == "/" && $4 ~ /^ro(,|$)/ { f = 1 } END { exit !f }' /proc/mounts || exit 0
E=$(cat /sys/fs/ext4/mmcblk0p5/errors_count 2>/dev/null)
case "$E" in ''|*[!0-9]*) exit 0 ;; esac
[ "$E" -gt 0 ] || exit 0
D=/opt/minui-zero/e2fsck
[ -x "$D/e2fsck" ] || exit 0
echo "root-check: $E error(s) recorded on the root filesystem, running e2fsck" >/dev/kmsg 2>/dev/null
LD_LIBRARY_PATH="$D" "$D/e2fsck" -y /dev/mmcblk0p5 >/dev/kmsg 2>&1
rc=$?
echo "root-check: e2fsck exit $rc" >/dev/kmsg 2>/dev/null
# 0 = clean, 1 = repaired, 2 = repaired and a restart is needed, 4+ = left errors (boot on: the old initramfs did too)
if [ $((rc & 3)) -ne 0 ]; then
	sync
	# as boardpick.sh's restart: the CPU rail at full voltage for the warm reset, and the SoC watchdog (8 s) in case
	# the reset never comes (reboot hangs, 2026-11-06)
	echo performance > /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null
	busybox devmem 0x030090b4 32 1; busybox devmem 0x030090b8 32 0x71; busybox devmem 0x030090b0 32 0x14af
	reboot -f
fi
exit 0
