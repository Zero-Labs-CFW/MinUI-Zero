# Rewrite muOS init/S10udev so udevd, its two triggers and the settle run in the background (boot speed, 2026-11-04).
# Nothing before the menu needs udev: the kernel's devtmpfs creates every /dev node itself (input included), muOS's
# module.sh loads the two modules this image uses by name, and our launcher reads evdev directly. The settle alone held
# the boot for 0.27 s and udev 0.57 s in all on the H. udevd still starts, so hotplug works as before.
# Quiet window (2026-11-05): udev also waits until the menu is on screen (platform.c drops /run/zero-menu-frame), 3 s at
# most, so its 3+ MB of cold reads (udevd, rules, libraries) do not compete with the menu for the card (measured on the
# Plus: the menu's first frame moved 0.33 s earlier).
/\/sbin\/udevd -d \|\| \{/ { print "\t\t( n=0; until [ -e /run/zero-menu-frame ] || [ $n -ge 60 ]; do sleep 0.05; n=$((n+1)); done"; print "\t\t/sbin/udevd -d || exit 1"; skip = 1; done_open = 1; next }
skip == 1 && /^\t\t}/ { skip = 2; next }
skip == 1 { next }
/udevadm settle --timeout=30/ { print; print "\t\t) >/dev/null 2>&1 &   # MinUI Zero: udev off the boot path"; done_close = 1; next }
{ print }
END { if (!done_open || !done_close) exit 3 }
