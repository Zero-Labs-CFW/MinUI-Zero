# Rewrite muOS mount/start.sh: the main card is mounted directly (FAT32, which the image and expand-roms.sh always
# make), muOS's storage.sh only as its fallback. Their three storage.sh runs in parallel took 0.45 s of every boot on the
# H (2026-11-04), for the one card that exists. The second card and USB, then the union and bind trees built from what
# is mounted, run as ONE background sequence, so a slow second card is still in them (Codex review 2026-11-04);
# startup.sh waits for the main card itself, and mount_ready (bind.sh) still releases it if that never mounts.
/storage\.sh "rom" "mount" 1 &/ {
	print "# MinUI Zero fast path (boot speed 2026-11-04): the main card directly, muOS's storage.sh as the fallback"
	print "if grep -q \" /mnt/mmc \" /proc/mounts || { mkdir -p /mnt/mmc && mount -t vfat -o rw,utf8,noatime,nofail /dev/mmcblk0p6 /mnt/mmc 2>/dev/null; }; then   # early.sh may have mounted it"
	print "\tSET_VAR \"device\" \"storage/rom/active\" \"1\""
	print "\tmkdir -p /mnt/mmc/ROMS"
	print "\t( echo deadline >/sys/block/mmcblk0/queue/scheduler; echo \"write through\" >/sys/block/mmcblk0/queue/write_cache; KERNEL_TUNING mmcblk0 ) 2>/dev/null &"
	print "else"
	print "\t/opt/muos/script/mount/storage.sh \"rom\" \"mount\" 1"
	print "fi"
	print "# second card, USB, then the union and bind trees over what is mounted: one sequence, off the boot path"
	print "("
	# the second card slot starts after init (early.sh, zero_late_mmc.ko) and muOS mounts it only here, never on a later
	# insert: wait for the slot (2 s at most), then for a card in it to identify (3 s; an empty slot pays this, in this
	# background sequence only); a card that does gets 5 s for its disk and 1 s more for its first partition, so
	# storage.sh mounts the partition rather than falling back to the whole disk (Codex review 2026-11-04)
	print "\tn=0; while [ ! -e /sys/class/mmc_host/mmc1 ] && [ $n -lt 20 ]; do sleep 0.1; n=$((n+1)); done"
	print "\tn=0; while ! ls -d /sys/class/mmc_host/mmc1/mmc1:* >/dev/null 2>&1 && [ $n -lt 30 ]; do sleep 0.1; n=$((n+1)); done"
	print "\tif ls -d /sys/class/mmc_host/mmc1/mmc1:* >/dev/null 2>&1; then"
	print "\t\tn=0; while ! [ -b /dev/mmcblk1 ] && [ $n -lt 50 ]; do sleep 0.1; n=$((n+1)); done"
	print "\t\tn=0; while [ -b /dev/mmcblk1 ] && ! [ -b /dev/mmcblk1p1 ] && [ $n -lt 10 ]; do sleep 0.1; n=$((n+1)); done"
	print "\tfi"
	print "\t/opt/muos/script/mount/storage.sh \"sdcard\" \"mount\" 1"
	print "\t/opt/muos/script/mount/storage.sh \"usb\" \"mount\" 1"
	print "\t/opt/muos/script/mount/union.sh start"
	print "\t/opt/muos/script/mount/bind.sh"
	print ") >/dev/null 2>&1 &"
	done = 1
	next
}
/storage\.sh "sdcard" "mount" 1 &/ { next }
/storage\.sh "usb" "mount" 1 &/ { next }
/^wait$/ { next }
/^\/opt\/muos\/script\/mount\/union\.sh start$/ { next }
/^\/opt\/muos\/script\/mount\/bind\.sh &$/ { next }
{ print }
END { if (!done) exit 3 }
