#!/bin/sh
# NOTE: becomes .tmp_update/tg5040.sh

PLATFORM="tg5040"
SDCARD_PATH="/mnt/SDCARD"
UPDATE_PATH="$SDCARD_PATH/MinUI.zip"
SYSTEM_PATH="$SDCARD_PATH/.system"

# LEDS OFF, FIRST THING. This used to sit ~35 lines down, after the remounts, the governor setup
# and the radio teardown. None of those need to happen first, and every line before this one is
# time the LEDs are lit for no reason. They are still lit BEFORE this script runs at all (the
# firmware's own init owns the boot-logo phase), which is what /mnt/UDISK/system.json is for; this
# just closes our half of the window as early as we possibly can. Writes to a zone the device does
# not have fail harmlessly, which is why max_scale_rear (Brick Pro only) is safe here unguarded.
# Ambient RGB LEDs off every boot (not just on install) — Zero has no ambient-LED feature, so they're
# a rail we never use. Cheap insurance in case an OFW update re-enables them.
echo 0 > /sys/class/led_anim/max_scale 2>/dev/null
echo 0 > /sys/class/led_anim/max_scale_lr 2>/dev/null
echo 0 > /sys/class/led_anim/max_scale_f1f2 2>/dev/null
	# Brick Pro only: the shoulder LEDs are a FOURTH zone and ship lit at 40. This is the block
	# that runs on EVERY boot; the copy inside the install branch below was fixed first and this one
	# was missed, leaving the shoulders lit from power-on until the launcher finally zeroes them.
	echo 0 > /sys/class/led_anim/max_scale_rear 2>/dev/null

# for Brick (noatime: nothing reads atime, so skip the per-access metadata writeback to SD)
mount -o remount,rw,async,noatime "$SDCARD_PATH"
mount -o remount,rw,async,noatime "/mnt/UDISK"

# Persist "LEDs off" where the FIRMWARE reads it, not just in sysfs. The sysfs writes above hold
# only for this boot and only from the moment this script runs; the boot-logo phase belongs to the
# firmware's own init, which configures LEDs from /mnt/UDISK/system.json. MinUI.pak/launch.sh
# already sweeps these keys, but that is ~a second later and does not run at all on a boot that
# ends early, so do it here too, as soon as UDISK is writable. Idempotent: a no-op once zeroed.
# (Brick Pro showed lit stick rings and strip LEDs through the boot logo, 2026-08-30.)
STOCK_JSON=/mnt/UDISK/system.json
if [ -f "$STOCK_JSON" ]; then
	sed -i -e "s/\"topled\":[[:space:]]*[0-9]*/\"topled\":\t0/" \
	       -e "s/\"shoulderled\":[[:space:]]*[0-9]*/\"shoulderled\":\t0/" \
	       -e "s/\"f1f2led\":[[:space:]]*[0-9]*/\"f1f2led\":\t0/" \
	       -e "s/\"joystickled\":[[:space:]]*[0-9]*/\"joystickled\":\t0/" \
	       -e "s/\"ledswitch\":[[:space:]]*[0-9]*/\"ledswitch\":\t0/" "$STOCK_JSON" 2>/dev/null
fi

# Hybrid CPU control: prefer schedutil (the governor sets a scaling_max_freq cap and the
# kernel picks beneath it). Verify by read-back; if schedutil is unavailable, fall back to
# the known-good userspace path at a NON-OC clock. Either way: never 2.0GHz (overclock).
GOV=/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
echo schedutil > "$GOV" 2>/dev/null
if [ "$(cat "$GOV" 2>/dev/null)" = "schedutil" ]; then
	echo 1800000 > /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq 2>/dev/null || true
else
	echo userspace > "$GOV" 2>/dev/null || true
	echo 1608000 > /sys/devices/system/cpu/cpu0/cpufreq/scaling_setspeed 2>/dev/null || true
fi

# MinUI Zero: radios off by default. MinUI has no networking, so full-time wifi/BT is pure wasted
# power. Bluetooth is always disabled (no feature uses it); wifi stays up ONLY when the dev
# enable-ssh flag is present (SSH access). Zero user-facing loss, less idle drain + heat.
SHARED_UD="$SDCARD_PATH/.userdata/shared"
killall -q bluetoothd bluealsa hciattach 2>/dev/null
[ -x /etc/init.d/hciattach ] && /etc/init.d/hciattach stop >/dev/null 2>&1
for r in /sys/class/rfkill/rfkill*; do
	[ "$(cat "$r/type" 2>/dev/null)" = "bluetooth" ] && echo 0 > "$r/state" 2>/dev/null
done
if [ ! -f "$SHARED_UD/enable-ssh" ]; then
	killall -q wpa_supplicant 2>/dev/null
	ifconfig wlan0 down 2>/dev/null
	for r in /sys/class/rfkill/rfkill*; do
		[ "$(cat "$r/type" 2>/dev/null)" = "wlan" ] && echo 0 > "$r/state" 2>/dev/null
	done
fi


# install/update
if [ -f "$UPDATE_PATH" ]; then
	export LD_LIBRARY_PATH=/usr/trimui/lib:$LD_LIBRARY_PATH
	export PATH=/usr/trimui/bin:$PATH

	TRIMUI_MODEL=`strings /usr/trimui/bin/MainUI | grep ^Trimui`
	# The Brick Pro reports "Trimui Brick Pro" and is its OWN device (see is_brickpro in
	# platform.h): same 1024x768 panel and @3x assets as the Brick, but a different rumble drive
	# and extra buttons. Naming it "brick" would have silently over-driven its motor. Split taken
	# from NextUI's shipped tg5040 support, the only tested Brick Pro reference.
	case "$TRIMUI_MODEL" in
		"Trimui Brick Pro") DEVICE="brickpro" ;;
		"Trimui Brick")     DEVICE="brick" ;;
	esac

	# leds_off
	echo 0 > /sys/class/led_anim/max_scale
	if [ "$DEVICE" = "brick" ] || [ "$DEVICE" = "brickpro" ]; then
		echo 0 > /sys/class/led_anim/max_scale_lr
		echo 0 > /sys/class/led_anim/max_scale_f1f2
		# Brick Pro only: the shoulder LEDs live in their own zone and ship lit at 40.
		echo 0 > /sys/class/led_anim/max_scale_rear 2>/dev/null
	fi
	
	cd $(dirname "$0")/$PLATFORM
	if [ -d "$SYSTEM_PATH" ]; then
		ACTION=updating
	else
		ACTION=installing
	fi
	# $DEVICE is NOT a valid artwork folder on its own: we ship ./brick/ and the Smart Pro images
	# at the root, and there is no ./brickpro/. The Brick Pro shares the Brick's 1024x768 panel,
	# so it shares its artwork; interpolating $DEVICE raw would 404 to a blank splash.
	IMG_DIR="$DEVICE"
	[ "$IMG_DIR" = "brickpro" ] && IMG_DIR="brick"
	./show.elf ./$IMG_DIR/$ACTION.png
	
	# CRC-test the whole archive before touching the installed system (audit 2026-07-12:
	# extracting unverified and unconditionally deleting the package could leave a partial
	# install with no recovery copy). On extraction failure the package is renamed aside —
	# kept for diagnosis but unable to install-loop; a power-cut mid-extract leaves the
	# package in place so the next boot retries.
	UPDATED=
	COPY_OK=0
	STAGE="$SDCARD_PATH/.minui-staging"   # inert name: nothing boots from it
	rm -rf "$STAGE"
	if ! ./unzip -tqq "$UPDATE_PATH" > /dev/null 2>&1; then
		mv -f "$UPDATE_PATH" "$UPDATE_PATH.bad"
	# ...and that it is a payload for THIS platform. A release archive for another device is
	# perfectly VALID, so the CRC test above passes it, and extracting it wrote another device's
	# .system over this one and then deleted the only copy of the archive: a working console
	# turned into one that needs a PC. The README tells users to update by dropping MinUI.zip on
	# the card, and the release page offers an archive per device, so picking the wrong one is an
	# ordinary mistake rather than an exotic one.
	#
	# The Miyoo installer has always checked this (see its boot.sh, same grep); tg5040 never did.
	# That was drift, not an earned divergence.
	#
	# Change NOTHING on rejection, matching the Miyoo behaviour: the installed system still boots,
	# and the archive is KEPT so the user can simply replace it with the right one and reboot.
	elif ! ./unzip -l "$UPDATE_PATH" 2>/dev/null | grep -q "$PLATFORM/paks/MinUI.pak/launch.sh"; then
		echo "$(date '+%F %T') This MinUI.zip is a valid archive but does not contain a $PLATFORM system - it is probably the download for a different device. Nothing was changed and the file was kept; replace it with the $PLATFORM release and reboot." > "$SDCARD_PATH/MinUI-update-failed.txt"
		sync
	# STAGE THE EXTRACT. This used to run `unzip -o ... -d "$SDCARD_PATH"`, straight over the live
	# tree. A CRC-valid archive can still fail to extract — the card fills, or the power goes — and
	# that left .system as a mix of old and new binaries while the archive was renamed aside, so
	# there was nothing left to retry from. Nothing touches the installed system until the whole
	# payload is on disk and has been checked.
	#
	# This is the pattern the Miyoo installer has used since its own audit; tg5040 never got it.
	# Same drift as the platform check above.
	elif ! mkdir -p "$STAGE"; then
		echo "$(date '+%F %T') Could not create a staging folder on the card - it may be full or write-protected. Nothing was changed." > "$SDCARD_PATH/MinUI-update-failed.txt"
		sync
	elif ./unzip -o "$UPDATE_PATH" -d "$STAGE" && [ -f "$STAGE/.system/$PLATFORM/paks/MinUI.pak/launch.sh" ]; then
		# Payload is complete on disk. Only now merge it into the live tree.
		#
		# `.tmp_update` MUST be copied explicitly. A glob of "$STAGE"/* does not match dotfiles, so
		# an earlier version of this silently skipped it — the install reported success, consumed
		# the archive, and left the OLD tg5040.sh and updater in place. Nothing visibly failed,
		# which is what made it dangerous: the safety-critical bootstrap could never self-update.
		cp -rf "$STAGE/.system" "$SDCARD_PATH/" && COPY_OK=1
		# Refresh ONLY the install/update splash images in the live bootstrap from the staged
		# payload. Safe by construction: a splash image is inert — a truncated copy just fails to
		# display — unlike the updater binary and boot script above it, which we still never touch.
		# This keeps the "MinUI Zero" branding current when a device's original bootstrap predates
		# it. Overwrites existing images only; never creates files, so it cannot alter structure.
		if [ -d "$STAGE/.tmp_update/$PLATFORM" ]; then
			for _sp in "$STAGE/.tmp_update/$PLATFORM"/updating.png "$STAGE/.tmp_update/$PLATFORM"/installing.png \
			           "$STAGE/.tmp_update/$PLATFORM"/*/updating.png "$STAGE/.tmp_update/$PLATFORM"/*/installing.png; do
				[ -f "$_sp" ] || continue
				_dst="$SDCARD_PATH/.tmp_update/$PLATFORM/${_sp#$STAGE/.tmp_update/$PLATFORM/}"
				[ -f "$_dst" ] && cp -f "$_sp" "$_dst" 2>/dev/null
			done
			sync
		fi
		# .tmp_update IS DELIBERATELY NOT INSTALLED HERE. Copying it merges over the LIVE bootstrap,
		# including the tg5040.sh that is executing right now, and `cp` truncates before writing: a
		# power cut mid-copy leaves a truncated `updater` that the firmware hook still finds by
		# presence, `exec`s, and fails on — with its stock fallback unreachable. That needs a PC.
		#
		# The consequence of leaving it out is that the bootstrap cannot self-update: a new
		# tg5040.sh ships in the archive but the installed one keeps running. That is a missing
		# feature, not a brick, and it is the behaviour every released version has had.
		#
		# Doing this properly needs the inert-stage + checked-atomic-promote treatment the OUTER
		# bootstrap now uses, applied to a directory whose contents are mid-execution. That is worth
		# doing carefully rather than quickly — see the note in docs/qol-backlog.md.
		for extra in "$STAGE"/* "$STAGE"/.[!.]*; do
			case "$(basename "$extra")" in .system|.tmp_update|"*"|".[!.]*") continue;; esac
			[ -e "$extra" ] && cp -rf "$extra" "$SDCARD_PATH/" 2>/dev/null
		done

		# COMMIT BEFORE DISCARDING THE WAY BACK. The card is remounted `async` at the top of this
		# script, so deleting the staging tree and the archive can reach the disk before the merged
		# file data does. A power cut in that window left a partial .system with no stage and no
		# archive — no dishonest card required. Make the merge durable first.
		sync
		rm -rf "$STAGE"
		if [ "${COPY_OK:-0}" = "1" ]; then
			rm -f "$UPDATE_PATH" "$SDCARD_PATH/MinUI-update-failed.txt"   # success: an old failure note is now false
			UPDATED=yes
		else
			echo "$(date '+%F %T') Update failed while installing (the card may be full). MinUI.zip was kept - free some space and reboot to retry." > "$SDCARD_PATH/MinUI-update-failed.txt"
		fi
	else
		# Extract failed or the payload was not what it claimed. The live system was never touched.
		rm -rf "$STAGE"
		mv -f "$UPDATE_PATH" "$UPDATE_PATH.failed"
	fi
	sync

	if [ "$UPDATED" = "yes" ]; then
		# the updated system finishes the install/update
		if [ -f $SYSTEM_PATH/$PLATFORM/bin/install.sh ]; then
			$SYSTEM_PATH/$PLATFORM/bin/install.sh # &> $SDCARD_PATH/log.txt
		fi

		if [ "$ACTION" = "installing" ]; then
			reboot
		fi
	fi
fi

LAUNCH_PATH="$SYSTEM_PATH/$PLATFORM/paks/MinUI.pak/launch.sh"
if [ -f "$LAUNCH_PATH" ] ; then
	exec "$LAUNCH_PATH"
fi

# NO LAUNCHER — MinUI is not installed, and we reached here without a usable archive to install it
# from (a corrupt download, or an install that failed and had nothing left to retry).
#
# Simply falling off the end of this script leaves a BLACK SCREEN. Our wrapper in
# /usr/trimui/bin/runtrimui.sh has already `exec`ed this script, so there is no caller to return to
# and its own stock fallback is unreachable — that `else` branch only runs when .tmp_update/updater
# is missing entirely. The device looks dead even though nothing is broken in the firmware.
#
# (It is recoverable without a PC by removing the card, which makes the wrapper take its stock
# branch. But a user with a blank screen has no way to know that.)
#
# So hand the device back to stock for this boot. The wrapper stays installed, so simply fixing the
# card — dropping a good MinUI.zip on it — makes the next boot install normally.
if [ -x /usr/trimui/bin/runtrimui-original.sh ]; then
	exec /usr/trimui/bin/runtrimui-original.sh
fi
