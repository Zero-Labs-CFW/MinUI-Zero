#!/bin/sh
# MiniUI.pak

#######################################

export PLATFORM="tg5040"
export SDCARD_PATH="/mnt/SDCARD"

# devmode flag: accept both "devmode" and "devmode.txt" at the card root, matching every
# other card-root flag (flagExists in C does the same). Dev mode = stay-awake + SSH.
devmode() { [ -f "$SDCARD_PATH/devmode" ] || [ -f "$SDCARD_PATH/devmode.txt" ]; }

export BIOS_PATH="$SDCARD_PATH/Bios"
export ROMS_PATH="$SDCARD_PATH/Roms"
export SAVES_PATH="$SDCARD_PATH/Saves"
export SYSTEM_PATH="$SDCARD_PATH/.system/$PLATFORM"
export CORES_PATH="$SYSTEM_PATH/cores"
export USERDATA_PATH="$SDCARD_PATH/.userdata/$PLATFORM"
export SHARED_USERDATA_PATH="$SDCARD_PATH/.userdata/shared"
export LOGS_PATH="$USERDATA_PATH/logs"
export DATETIME_PATH="$SHARED_USERDATA_PATH/datetime.txt"

# RTC sanity (the Onion/stock-MinUI trick, restore half): a fully dead battery resets the
# RTC to epoch. If the clock reads obvious nonsense, restore the last-known-good time that
# the launch loop already saves after every game — the clock loses only the time spent
# dead, not four decades.
if [ "$(date +%Y)" -lt 2025 ] && [ -f "$DATETIME_PATH" ]; then
	date -s "$(cat "$DATETIME_PATH")" >/dev/null 2>&1
	hwclock -w -u 2>/dev/null # -u: kernel reads the RTC as UTC at boot (busybox has no --utc)
fi

# TIMEZONE. The TrimUI firmware defaults to Asia/Shanghai (UTC+8) via /etc/localtime; the RTC is
# UTC. With no TZ of our own, a time set in the Clock tool reads back shifted by the vendor offset
# — for the Americas that is ~12h, i.e. the AM<->PM flip users reported (Brick Pro, 2026-09-03).
# Export TZ here so the menu AND the Clock tool (which inherit this env) agree, making what you set
# what you see, stable across reboot regardless of when the vendor restores /tmp/localtime.
# Drop a "timezone" file (or timezone.txt) at the card root: a zone name (America/New_York — 144
# US zones ship in /usr/share/zoneinfo) or a POSIX string (EST5EDT). No file = UTC, a plain wall
# clock you set once. (tg5040 only: this offset is a TrimUI-firmware default; other platforms
# carry their own clock handling — verify before copying.)
TZ_FILE="$SDCARD_PATH/timezone"
[ -f "$TZ_FILE" ] || TZ_FILE="$SDCARD_PATH/timezone.txt"
if [ -f "$TZ_FILE" ]; then
	export TZ="$(head -1 "$TZ_FILE" | tr -d ' \t\r\n')"
else
	export TZ="UTC"
fi

mkdir -p "$BIOS_PATH"
mkdir -p "$ROMS_PATH"
mkdir -p "$SAVES_PATH"
mkdir -p "$USERDATA_PATH"
mkdir -p "$LOGS_PATH"
mkdir -p "$SHARED_USERDATA_PATH/.minui"

# macs and windows leave droppings on any card they mount (Spotlight index, fsevents logs,
# ._* resource forks, .DS_Store, System Volume Information). Sweep them each boot; the
# .metadata_never_index and .fseventsd/no_log markers shipped in the zip prevent most of it.
rm -rf "$SDCARD_PATH/.Spotlight-V100" "$SDCARD_PATH/.Trashes" "$SDCARD_PATH/System Volume Information" 2>/dev/null
touch "$SDCARD_PATH/.metadata_never_index" 2>/dev/null
mkdir -p "$SDCARD_PATH/.fseventsd" && touch "$SDCARD_PATH/.fseventsd/no_log" 2>/dev/null
find "$SDCARD_PATH/.fseventsd" -type f ! -name no_log -delete 2>/dev/null
rm -f "$SDCARD_PATH/.DS_Store" "$SDCARD_PATH"/._* 2>/dev/null
( find "$ROMS_PATH" "$BIOS_PATH" "$SAVES_PATH" \( -name "._*" -o -name ".DS_Store" \) -delete 2>/dev/null & )

# v1.3 migration: saved PS cfgs snapshot ALL core options, so pre-v1.3 saves pin
# pcsx_rearmed_gpu_thread_rendering=auto forever, silently overriding the new disabled
# default (the async GPU thread serializes on the A133P; DECISIONS D48 — this trap bit
# both dev devices within hours). Run once per card; do not keep rewriting user config
# after the migration has completed successfully.
_gpu_migration="$SHARED_USERDATA_PATH/.minui/migrated-v13-gpu-thread-disabled"
if [ ! -f "$_gpu_migration" ]; then
	_gpu_migration_failed=0
	for _cfg in "$USERDATA_PATH/PS-pcsx_rearmed"/*.cfg; do
		[ -f "$_cfg" ] || continue
		if grep -q "pcsx_rearmed_gpu_thread_rendering = auto" "$_cfg"; then
			sed -i "s/pcsx_rearmed_gpu_thread_rendering = auto/pcsx_rearmed_gpu_thread_rendering = disabled/" "$_cfg" || _gpu_migration_failed=1
			grep -q "pcsx_rearmed_gpu_thread_rendering = auto" "$_cfg" && _gpu_migration_failed=1
		fi
	done 2>/dev/null
	if [ "$_gpu_migration_failed" = "0" ]; then
		: > "$_gpu_migration.tmp" && mv "$_gpu_migration.tmp" "$_gpu_migration"
		sync
	fi
fi
unset _cfg _gpu_migration _gpu_migration_failed

# v1.4.1 migration: old FC configs retain upstream's fceumm High sound-quality
# setting even though the pak default moved to Low. High costs roughly 400 MHz and
# measured substantially more underruns; saved configs otherwise override the fix.
_fc_migration="$SHARED_USERDATA_PATH/.minui/migrated-v141-fceumm-low"
if [ ! -f "$_fc_migration" ]; then
	_fc_migration_failed=0
	for _cfg in "$USERDATA_PATH/FC-fceumm"/*.cfg; do
		[ -f "$_cfg" ] || continue
		if grep -q "fceumm_sndquality = High" "$_cfg"; then
			_fc_tmp="$_cfg.v141.tmp"
			_fc_has_low=1
			_fc_has_high=2
			if sed "s/fceumm_sndquality = High/fceumm_sndquality = Low/" "$_cfg" > "$_fc_tmp"; then
				grep -q "fceumm_sndquality = Low" "$_fc_tmp"; _fc_has_low=$?
				grep -q "fceumm_sndquality = High" "$_fc_tmp"; _fc_has_high=$?
			fi
			if [ "$_fc_has_low" = "0" ] && [ "$_fc_has_high" = "1" ] && mv "$_fc_tmp" "$_cfg"; then
				:
			else
				rm -f "$_fc_tmp"
				_fc_migration_failed=1
			fi
		fi
	done 2>/dev/null
	if [ "$_fc_migration_failed" = "0" ]; then
		sync
		: > "$_fc_migration.tmp" && mv "$_fc_migration.tmp" "$_fc_migration"
		sync
	fi
fi
unset _cfg _fc_tmp _fc_has_low _fc_has_high _fc_migration _fc_migration_failed

# dev: Stay Awake tool persistence (workspace/tg5040/dev-tools/, never shipped) — the
# /tmp flag resets each boot, so re-arm from the shared flag. Inert unless a dev armed it.
if [ -f "$SHARED_USERDATA_PATH/dev-stay-awake" ]; then
	touch /tmp/stay_awake
	iw dev wlan0 set power_save off 2>/dev/null
	iwconfig wlan0 power off 2>/dev/null
	# net-keeper self-heals a wedged wifi driver (dev tool file; absent on shipped cards)
	NK="$SDCARD_PATH/Tools/$PLATFORM/Stay Awake.pak/net-keeper.sh"
	[ -f "$NK" ] && ( /bin/sh "$NK" </dev/null >/dev/null 2>&1 ) &
fi

# model detection: NO caching — the SD card can move between a Brick and a Smart Pro
# (same tg5040 platform), and a cached model would misdetect after the swap (wrong pad
# init, wrong LED/keymon handling). The MainUI binary lives on the DEVICE, not the card,
# so it must be read fresh each boot. (A cache shipped briefly on 2026-07-02 — reverted.)
export TRIMUI_MODEL=`strings /usr/trimui/bin/MainUI | grep ^Trimui`
# PANEL RATE, per model, MEASURED — feeds minarch's Zero_applyRateMatch so audio production is
# resampled to the panel's true rate. Unset = rate match inert (the pre-2026-08-31 behavior).
# The +0.4% surplus of an unmatched 60.18Hz panel over a 59.94 core slowly PINNED the audio
# ring full, and ring-full backpressure stalling the threaded pipeline was the PS1 sustained
# judder (~14s onset). Brick Pro: fb0 timings read on-device (D 57.003MHz -> V 60.180 Hz).
# Brick / Smart Pro: NOT yet measured on their panels — leave unset there rather than guess.
if [ "$TRIMUI_MODEL" = "Trimui Brick Pro" ]; then
	export MINARCH_PANEL_FPS=60.180
elif [ "$TRIMUI_MODEL" = "Trimui Brick" ]; then
	# Brick panel measured 2026-08-31 off its live fb0 scanout timings (D 51.002MHz -> V 60.235 Hz).
	export MINARCH_PANEL_FPS=60.235
fi
# Audio ring occupancy servo: a +-0.5% trim on top of the static rate match that refills the
# ring after a stall drains it (nothing else does). Only acts where a static match is live, so
# the Smart Pro (unset above) is untouched. Miyoo and Anbernic do not export it until ear-checked
# there (their launch.sh say why). ZERO_AUDIO_SERVO=0 kills it for an A/B.
export ZERO_AUDIO_SERVO=1
# Smart Pro stays UNSET on purpose: its fb0 reports 63.965 Hz but the SP scans the GLES layer,
# not fb0, so that number is unverified for the actual panel. Measure vsync-derived before arming.
# The Brick Pro reports "Trimui Brick Pro". An exact test for "Trimui Brick" left DEVICE empty and
# platform.h is_brick then picked Smart Pro geometry: 1280x720 at @2x with 10 menu rows, which is
# the squashed menu Dan photographed (2026-08-28). It gets its OWN device rather than being called
# a Brick: same 1024x768 panel and @3x assets, but a lower rumble drive voltage. See is_brickpro.
case "$TRIMUI_MODEL" in
	"Trimui Brick Pro") export DEVICE="brickpro" ;;
	"Trimui Brick")     export DEVICE="brick" ;;
esac
rm -f "$SHARED_USERDATA_PATH/.minui/model" # clean up the briefly-shipped cache
# HARDWARE DIAGNOSTIC. The model test above is exact, so a TrimUI whose string we have never seen
# leaves DEVICE unset and is treated as a Smart Pro. That is now a real third-model risk rather
# than a hypothetical: the Brick Pro reports "Trimui Brick Pro" and was mis-sized exactly that way
# until it got its own branch (2026-08-30, panel since measured at 1024x768). Keep recording what
# the device ACTUALLY reports so the NEXT unknown model is diagnosable from the card instead of
# guessed. Rather than guess its panel, record what the device ACTUALLY said plus the real fb0
# geometry, so first boot on new hardware is diagnosable from the card. One line per boot.
# virtual_size alone is NOT enough: on the Brick Pro it read "1024,16384", where 16384 is the
# virtual scrollback height, not the visible one (2026-08-28). Record the visible mode too.
printf 'model=%s\ndevice=%s\nvirtual_size=%s\nmodes=%s\nstride=%s\n' \
	"${TRIMUI_MODEL:-<none>}" "${DEVICE:-<unset, using Smart Pro geometry>}" \
	"$(cat /sys/class/graphics/fb0/virtual_size 2>/dev/null || echo '<unreadable>')" \
	"$(m=$(cat /sys/class/graphics/fb0/modes 2>/dev/null) && [ -n "$m" ] && printf '%s' "$m" | tr '\n' ' ' || echo '<unreadable>')" \
	"$(cat /sys/class/graphics/fb0/stride 2>/dev/null || echo '<unreadable>')" \
	> "$LOGS_PATH/model.txt" 2>/dev/null

#######################################

#rumble motor PH3
echo 227 > /sys/class/gpio/export
echo -n out > /sys/class/gpio/gpio227/direction
echo -n 0 > /sys/class/gpio/gpio227/value

if [ "$TRIMUI_MODEL" = "Trimui Smart Pro" ]; then
	#Left/Right Pad PD14/PD18
	echo 110 > /sys/class/gpio/export
	echo -n out > /sys/class/gpio/gpio110/direction
	echo -n 1 > /sys/class/gpio/gpio110/value

	echo 114 > /sys/class/gpio/export
	echo -n out > /sys/class/gpio/gpio114/direction
	echo -n 1 > /sys/class/gpio/gpio114/value
fi

#DIP Switch PH19
echo 243 > /sys/class/gpio/export
echo -n in > /sys/class/gpio/gpio243/direction

#######################################

export LD_LIBRARY_PATH=$SYSTEM_PATH/lib:/usr/trimui/lib:$LD_LIBRARY_PATH
export PATH=$SYSTEM_PATH/bin:/usr/trimui/bin:$PATH

#######################################

# leds_off
echo 0 > /sys/class/led_anim/max_scale
if [ "$DEVICE" = "brick" ] || [ "$DEVICE" = "brickpro" ]; then
	echo 0 > /sys/class/led_anim/max_scale_lr
	echo 0 > /sys/class/led_anim/max_scale_f1f2
	# The Brick Pro has a FOURTH zone the Brick does not: max_scale_rear, the shoulder LEDs, which
	# ship lit at 40 and stayed on through every other zone being zeroed (read off the device
	# 2026-08-30). Absent on the Brick, where the write simply fails and costs nothing.
	echo 0 > /sys/class/led_anim/max_scale_rear 2>/dev/null
fi
# ...and keep them off: trimui_inputd re-arms the scales from /mnt/UDISK/system.json on every
# button press (verified on-device 2026-07-01 — first keypress after boot relit the LEDs at
# scale 60). Zero the stock config too, BEFORE inputd starts, so it reads "off" at startup.
STOCK_JSON=/mnt/UDISK/system.json
if [ -f "$STOCK_JSON" ]; then
	sed -i -e "s/\"topled\":[[:space:]]*[0-9]*/\"topled\":\t0/" \
	       -e "s/\"shoulderled\":[[:space:]]*[0-9]*/\"shoulderled\":\t0/" \
	       -e "s/\"f1f2led\":[[:space:]]*[0-9]*/\"f1f2led\":\t0/" \
	       -e "s/\"joystickled\":[[:space:]]*[0-9]*/\"joystickled\":\t0/" \
	       -e "s/\"ledswitch\":[[:space:]]*[0-9]*/\"ledswitch\":\t0/" "$STOCK_JSON"
fi

# USB: charge-only unless dev mode. Stock "data" mode enumerates MTP + adb when plugged into a
# computer — MtpDaemon then indexes the whole SD while games stream from it (measured 2026-07-02:
# the I/O contention visibly stretches frame times), plus two resident daemons of pure waste.
# MinUI has no USB-data feature, so a plugged-in Zero should just charge. The enable-ssh dev flag
# keeps stock "data" mode (adb as a wifi-less fallback for development).
if [ ! -f "$SHARED_USERDATA_PATH/enable-ssh" ] && [ -f "$STOCK_JSON" ]; then
	sed -i -e "s/\"usbmode\":[[:space:]]*\"[a-z]*\"/\"usbmode\":\t\"charge\"/" "$STOCK_JSON"
fi
# set default usb mode (reads usbmode from the stock config). Backgrounded: the final
# kernel-attribute read blocks ~2.3s while the USB stack initializes — measured as the
# single biggest cost in our whole boot path, and nothing before the menu depends on it.
usb_device.sh &

# First-boot polish (baked in from the old Bootlogo + Remove Loading tools — see git history).
# Runs once, guarded by a flag; every step is non-fatal so a failure never blocks boot.
# SCOPED PER MODEL, deliberately. The flag lives on the CARD but everything it guards is written
# to the DEVICE (/etc/init.d/runtrimui, the eMMC boot partition), so a single unscoped flag meant
# the first machine a card touched consumed the polish for every later one. The Brick Pro hit this
# exactly: its first boot spent the flag while the model was still unrecognised and LOGO was empty,
# so it could never get a boot logo afterwards no matter how many times it booted (2026-08-30).
# ---- once per model: edits to the DEVICE rootfs that only ever need doing once ---------------
# Scoped per model on purpose. The flag lives on the CARD but what it guards is written to the
# DEVICE, so a single unscoped flag meant the first machine a card touched consumed the work for
# every later one. The Brick Pro hit exactly that.
FIRSTRUN="$SHARED_USERDATA_PATH/.minui/zero-firstrun-${DEVICE:-smartpro}"
rm -f "$SHARED_USERDATA_PATH/.minui/zero-firstrun-done" # retire the old unscoped flag
if [ ! -f "$FIRSTRUN" ]; then
	# Remove Loading: drop the stock splash line so boot goes straight to MinUI (no flash).
	# A failure must block the marker, or a read-only/full rootfs is recorded as done and the
	# splash is never removed on any later boot.
	POLISH_OK=1
	if [ -f /etc/init.d/runtrimui ]; then
		sed -i '/^\/usr\/sbin\/pic2fb \/etc\/splash.png/d' /etc/init.d/runtrimui 2>/dev/null || POLISH_OK=0
	fi
	if [ "$POLISH_OK" = "1" ]; then
		touch "$FIRSTRUN"
		sync
	fi
fi

# ---- every boot, but a no-op unless the SHIPPED LOGO CHANGED ----------------------------------
# This deliberately does NOT sit behind the first-run flag. It used to, and that made a shipped
# asset unreachable: once a device had booted once, redrawing the boot logo could never reach it
# again. Exactly what happened on the Brick Pro (2026-08-30) - the card carried the new wordmark
# while the eMMC kept the first, too-small one, and no amount of rebooting could fix it.
#
# The gate is the ASSET's own content instead, so a redraw re-arms this automatically and an
# unchanged logo costs one md5sum and one file test per boot, never an eMMC remount.
#
# MODEL-SPECIFIC assets: each bootloader expects its own BMP geometry and writing the wrong one
# renders garbled. Dimensions are MEASURED, not assumed:
#   Brick 216x237x24   Smart Pro 128x128x32   Brick Pro 396x66x24
if [ "$TRIMUI_MODEL" = "Trimui Brick" ]; then
	LOGO="$SYSTEM_PATH/dat/bootlogo.bmp"
elif [ "$TRIMUI_MODEL" = "Trimui Brick Pro" ]; then
	# Shares the BRICK's asset, deliberately. The Brick Pro's vendor logo is a 396x66 banner, and
	# a purpose-made 396x66 file was tried first on the assumption that the bootloader demanded
	# those dimensions. It does not: writing the Brick's own 216x237 mark to this device's boot
	# partition renders correctly (tested on hardware 2026-08-30). So the bootloader parses the
	# BMP header and there is no reason to carry a second, smaller, differently-drawn asset.
	LOGO="$SYSTEM_PATH/dat/bootlogo.bmp"
elif [ "$TRIMUI_MODEL" = "Trimui Smart Pro" ]; then
	LOGO="$SYSTEM_PATH/dat/bootlogo-smartpro.bmp"
else
	LOGO="" # unknown model: leave the vendor logo alone
fi
if [ -n "$LOGO" ] && [ -f "$LOGO" ]; then
	LOGO_STAMP="$SHARED_USERDATA_PATH/.minui/zero-bootlogo-$(md5sum "$LOGO" 2>/dev/null | cut -c1-8)"
	if [ ! -f "$LOGO_STAMP" ]; then
		BOOTMNT=/tmp/zero-boot
		mkdir -p "$BOOTMNT"
		if mount -t vfat /dev/mmcblk0p1 "$BOOTMNT" 2>/dev/null; then
			# Temp name + rename so a failed copy cannot truncate a good logo. Sync the finished
			# temp BEFORE the rename and again after: VFAT has no journal, so this is the best
			# this filesystem offers, not a crash guarantee.
			if cp "$LOGO" "$BOOTMNT/bootlogo.bmp.new" 2>/dev/null && sync &&
			   mv "$BOOTMNT/bootlogo.bmp.new" "$BOOTMNT/bootlogo.bmp" 2>/dev/null; then
				sync
				rm -f "$SHARED_USERDATA_PATH/.minui/zero-bootlogo-"* 2>/dev/null
				touch "$LOGO_STAMP"
				sync
			else
				rm -f "$BOOTMNT/bootlogo.bmp.new" 2>/dev/null
			fi
			umount "$BOOTMNT" 2>/dev/null
		fi
		rmdir "$BOOTMNT" 2>/dev/null
	fi
fi

# match stock audio
tinymix set 9 1
tinymix set 1 0

# start stock gpio input daemon
mkdir -p /tmp/trimui_inputd
trimui_inputd &

# Hybrid CPU control (see boot.sh): prefer schedutil + a scaling_max_freq cap; fall back to
# known-good userspace at a non-OC clock if schedutil is unavailable. Never 2.0GHz (OC).
GOV=/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
echo schedutil > "$GOV" 2>/dev/null
if [ "$(cat "$GOV" 2>/dev/null)" = "schedutil" ]; then
	CPU_PATH=/sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq
	CPU_SPEED_PERF=1800000
else
	echo userspace > "$GOV" 2>/dev/null || true
	CPU_PATH=/sys/devices/system/cpu/cpu0/cpufreq/scaling_setspeed
	CPU_SPEED_PERF=1608000
fi
echo $CPU_SPEED_PERF > $CPU_PATH 2>/dev/null || true

# networking: DEV MODE (wifi + SSH for testing) only if the opt-in flag exists,
# otherwise block all radios (default runs-cold behavior).
# WIFI OPT-IN, one visible file at the card root, matching h700: "SSID:password" in wifi.txt.
# The old way needed TWO files inside the hidden .userdata/shared folder (an empty enable-ssh
# flag plus a shell-syntax wifi.conf), which is a lot to ask of someone who just wants ssh, and
# it diverged from the Anbernic build for no reason (Dan, 2026-08-28). wifi.txt is translated to
# the existing pair here, so dev-net.sh and everything downstream are untouched, and the old
# files keep working for anyone already set up.
if [ -f "$SDCARD_PATH/wifi.txt" ]; then
	_w=$(sed '/^#/d;/^[[:space:]]*$/d' "$SDCARD_PATH/wifi.txt" | head -1)
	_ssid=${_w%%:*}; _psk=${_w#*:}
	if [ -n "$_ssid" ] && [ "$_ssid" != "$_w" ]; then
		mkdir -p "$SHARED_USERDATA_PATH"
		printf 'SSID=%s\nPSK=%s\n' "$_ssid" "$_psk" > "$SHARED_USERDATA_PATH/wifi.conf"
		touch "$SHARED_USERDATA_PATH/enable-ssh"
	fi
fi
# MtpDaemon and ntpd are USB/clock daemons with NOTHING to do with wifi or SSH, and they used to
# sit in the else branch below, so turning on wifi left them running for the whole session.
# MtpDaemon is the expensive one, indexing the entire card while games stream from it. Those two
# die in BOTH modes. adbd does NOT: dev mode keeps stock USB "data" mode on purpose so adb is a
# wifi-less fallback, so it is killed only in the non-dev branch below.
# (Found on the Brick Pro with wifi enabled, 2026-08-30; adbd carve-out added in review.)
killall MtpDaemon 2>/dev/null
killall ntpd 2>/dev/null # MinUI keeps its own clock
# DEV MODE is now unified on devmode.txt (Dan, 2026-09-08: "stay awake should just be Dev Mode ...
# add it to all the devices when devmode is active"). devmode.txt at the card root already arms
# stay-awake in C (PWR_init), so gating SSH on the SAME flag is what stops the reconnect rodeo: the
# device stays awake AND reachable together, the way the Miyoo already works. enable-ssh (which
# wifi.txt still creates above) stays a valid trigger so existing dev cards keep working.
if devmode || [ -f "$SHARED_USERDATA_PATH/enable-ssh" ]; then
	# adbd SURVIVES in dev mode on purpose: the USB block above keeps stock "data" mode precisely
	# so adb is available as a wifi-less fallback when ssh cannot be reached. Killing it here too
	# quietly removed that escape hatch (caught in review, 2026-08-30). MtpDaemon still dies either
	# way; it is the one that indexes the whole card while games stream from it.
	sh "$SYSTEM_PATH/bin/dev-net.sh" &
else
	killall adbd 2>/dev/null
	killall wpa_supplicant
	killall udhcpc
	rfkill block bluetooth
	rfkill block wifi
fi

keymon.elf & # &> $SDCARD_PATH/keymon.txt &

#######################################

# An armed calibration resumes from auto.sh below. Refresh its persistent harness from
# the just-installed pak first; otherwise an update can reboot into the older campaign
# code before the user opens Optimize CPU. Copy failure disarms and marks the campaign
# invalid rather than running mixed versions.
_uv_dir="$USERDATA_PATH/undervolt"
_uv_pak="$SDCARD_PATH/Tools/$PLATFORM/Optimize CPU.pak/bin"
if [ -f "$_uv_dir/ARMED" ]; then
	_uv_refresh_failed=0
	for _uv_file in uvtool stress uvmap.sh; do
		if [ ! -f "$_uv_pak/$_uv_file" ]; then
			_uv_refresh_failed=1
		elif [ ! -f "$_uv_dir/$_uv_file" ] || ! cmp -s "$_uv_pak/$_uv_file" "$_uv_dir/$_uv_file"; then
			cp "$_uv_pak/$_uv_file" "$_uv_dir/$_uv_file" 2>/dev/null && chmod +x "$_uv_dir/$_uv_file" || _uv_refresh_failed=1
		fi
		[ -f "$_uv_dir/$_uv_file" ] && chmod +x "$_uv_dir/$_uv_file" 2>/dev/null || _uv_refresh_failed=1
	done
	if [ "$_uv_refresh_failed" != "0" ]; then
		rm -f "$_uv_dir/ARMED" "$_uv_dir/state"
		touch "$_uv_dir/INVALID"
		sync
	fi
fi
unset _uv_dir _uv_pak _uv_file _uv_refresh_failed

AUTO_PATH=$USERDATA_PATH/auto.sh
if [ -f "$AUTO_PATH" ]; then
	"$AUTO_PATH"
fi

cd $(dirname "$0")

#######################################

# WiFi Toggle visibility (Dan, 2026-08-31): the tool appears in Tools ONLY when wifi is
# configured — wifi.txt (on) or wifi.txt.off (toggled off; must stay visible or there is no way
# back on). Unconfigured cards keep a clean Tools menu; the pak ships stashed in .system so
# updates always carry it, and this block is the sole owner of the Tools copy. Deploys that
# prune the Tools copy are self-healing: the next boot re-copies it.
WIFI_PAK_SRC="$SYSTEM_PATH/paks/tools-stash/WiFi Toggle.pak"
WIFI_PAK_DST="$SDCARD_PATH/Tools/tg5040/WiFi Toggle.pak"
if [ -f "$SDCARD_PATH/wifi.txt" ] || [ -f "$SDCARD_PATH/wifi.txt.off" ]; then
	[ -d "$WIFI_PAK_DST" ] || cp -r "$WIFI_PAK_SRC" "$WIFI_PAK_DST" 2>/dev/null
else
	rm -rf "$WIFI_PAK_DST" 2>/dev/null
fi
# Boot receipt, DEV CARDS ONLY (devmode.txt at the card root): kernel seconds at menu launch,
# one ~40-byte line per boot. Measured the fleet for the README table (2026-08-31); stays as a
# regression canary on dev cards and costs users nothing.
devmode && echo "$(cut -d" " -f1 /proc/uptime) menu-ready $(date +%Y-%m-%d 2>/dev/null)" >> "$LOGS_PATH/boot-time.txt"
EXEC_PATH="/tmp/minui_exec"
NEXT_PATH="/tmp/next"
touch "$EXEC_PATH" # tmpfs; a sync here would flush every filesystem for a file that never touches disk
while [ -f $EXEC_PATH ]; do
	if [ "$DEVICE" = "brick" ]; then
		# GPU-dark menu is BRICK-ONLY, for real (re-verified 2026-07-03 after a bad ungate):
		# writing fb0 produces correct CONTENTS on both devices, but only the Brick panel
		# SCANS OUT fb0 — the Smart Pro display pipeline shows the GLES layer, so fb-present
		# there = black screen while fb0 quietly holds a perfect menu. Do not ungate again
		# unless the SP scanout is actually rebound to fb0.
		ZERO_FB_PRESENT=1 minui.elf &> $LOGS_PATH/minui.txt
	else
		minui.elf &> $LOGS_PATH/minui.txt
	fi
	[ -f $EXEC_PATH ] && echo $CPU_SPEED_PERF > $CPU_PATH
	echo `date +'%F %T'` > "$DATETIME_PATH"
	sync
	
	if [ -f $NEXT_PATH ]; then
		CMD=`cat $NEXT_PATH`
		eval $CMD
		rm -f $NEXT_PATH
		[ -f $EXEC_PATH ] && echo $CPU_SPEED_PERF > $CPU_PATH
		echo `date +'%F %T'` > "$DATETIME_PATH"
		sync
	fi
done

exec shutdown
