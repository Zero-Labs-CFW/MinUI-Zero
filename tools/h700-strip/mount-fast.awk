# Rewrite muOS mount/start.sh: the main card is mounted directly (FAT32, which the image and expand-roms.sh always
# make), muOS's storage.sh only as its fallback. Their three storage.sh runs in parallel took 0.45 s of every boot on the
# H (2026-11-04), for the one card that exists. The second card and USB, then the union and bind trees built from what
# is mounted, run as ONE background sequence, so a slow second card is still in them (Codex review 2026-11-04);
# startup.sh waits for the main card itself, and mount_ready (bind.sh) still releases it if that never mounts.
/storage\.sh "rom" "mount" 1 &/ {
	print "# MinUI Zero fast path (boot speed 2026-11-04): the main card directly, muOS's storage.sh as the fallback"
	print "if mkdir -p /mnt/mmc && mount -t vfat -o rw,utf8,noatime,nofail /dev/mmcblk0p6 /mnt/mmc 2>/dev/null; then"
	print "\tSET_VAR \"device\" \"storage/rom/active\" \"1\""
	print "\tmkdir -p /mnt/mmc/ROMS"
	print "\t( echo deadline >/sys/block/mmcblk0/queue/scheduler; echo \"write through\" >/sys/block/mmcblk0/queue/write_cache; KERNEL_TUNING mmcblk0 ) 2>/dev/null &"
	print "else"
	print "\t/opt/muos/script/mount/storage.sh \"rom\" \"mount\" 1"
	print "fi"
	print "# second card, USB, then the union and bind trees over what is mounted: one sequence, off the boot path"
	print "("
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
