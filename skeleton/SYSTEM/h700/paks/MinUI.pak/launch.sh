#!/bin/sh
# MinUI Zero launcher entry point for h700 (Anbernic RG35XX Plus / H).
#
# WHY THIS FILE EXISTS. tg5040 and miyoomini have always had a MinUI.pak/launch.sh; h700 did not,
# because our own image starts the launcher by patching muOS's startup.sh instead
# (tools/build-h700-stripped.sh swaps its FRONTEND line for /opt/minui-zero/minui-frontend.sh).
# That works, but it is the only platform where the entry point lives in the OS rather than on the
# card, which (a) breaks the MinUI pak contract every other platform honours and (b) makes the
# frontend un-runnable on any OS layer other than our own muOS strip.
#
# PORTABLE ON PURPOSE. Everything muOS-specific below is guarded by a file test, so this script
# runs unmodified on our own image and on any bare OS layer that merely mounts the card and execs
# this path.
# Things the OS layer owns and this script must NOT duplicate: wifi, ssh, kernel modules, mounts.

# --- where is the card? muOS mounts it at /mnt/mmc; a bare OS layer may use /mnt/sdcard --------
if [ -d /mnt/mmc/.system/h700 ]; then
	export SDCARD_PATH="/mnt/mmc"
elif [ -d /mnt/sdcard/.system/h700 ]; then
	export SDCARD_PATH="/mnt/sdcard"
else
	# last resort: resolve from our own location, so an unknown mount point still works
	export SDCARD_PATH="$(cd "$(dirname "$0")/../../../.." 2>/dev/null && pwd)"
fi

export PLATFORM="h700"
export SYSTEM_PATH="$SDCARD_PATH/.system/$PLATFORM"
export CORES_PATH="$SYSTEM_PATH/cores"
export BIOS_PATH="$SDCARD_PATH/Bios"
export ROMS_PATH="$SDCARD_PATH/Roms"
export SAVES_PATH="$SDCARD_PATH/Saves"
export CHEATS_PATH="$SDCARD_PATH/Cheats"
export USERDATA_PATH="$SDCARD_PATH/.userdata/$PLATFORM"
export SHARED_USERDATA_PATH="$SDCARD_PATH/.userdata/shared"
export LOGS_PATH="$USERDATA_PATH/logs"
export DATETIME_PATH="$SHARED_USERDATA_PATH/datetime.txt"

# plus vs h are near-twins and the board name is how we tell them apart. Resolution order matters:
#   1. .system/h700/board, written into the payload by the image build. The image is per-device, so
#      this is the only source that is actually authoritative.
#   2. muOS's own board file, for a rootfs that still has muOS under it.
#   3. plus, as a last resort.
# There is deliberately NO device-tree fallback: this board reports "sun50iw9" for both models, so
# any match against it is a coin flip that reads as certainty (2026-08-27).
DEVICE=""
[ -f "$SYSTEM_PATH/board" ] && DEVICE=$(cat "$SYSTEM_PATH/board" 2>/dev/null | tr -d ' \n')
if [ -z "$DEVICE" ] && [ -f /opt/muos/device/config/board/name ]; then
	DEVICE=$(sed 's/^rg35xx-//' /opt/muos/device/config/board/name 2>/dev/null)
fi
[ -n "$DEVICE" ] || DEVICE=plus
export DEVICE

export LD_LIBRARY_PATH="$SYSTEM_PATH/lib:/usr/lib:/lib:$LD_LIBRARY_PATH"
export PATH="$SYSTEM_PATH/bin:$PATH"
# SDL2 here has exactly one video driver ("mali"); the launcher presents through the DE layer, so
# the dummy driver is correct and keeps SDL from initialising a GL context we never use.
export SDL_VIDEODRIVER=dummy
# DEVICE properties, so they live here rather than being repeated by all 15 emu paks (2026-08-26).
# Panel measured 59.9777 Hz (panelprobe 2026-08-04); minarch paces against the real rate, not 60.
export MINARCH_PANEL_FPS=59.9777
# ZERO_AUDIO_SERVO deliberately NOT exported here (tg5040 only for now): the occupancy servo
# trims the resampler on top of this match and is unmeasured on the ALSA-direct audio path.
# Ear-check on this device before arming (earned divergence, 2026-09-02).
# ALSA-direct: pipewire is stripped, and asound.conf routes "default" straight to the codec
# (plug -> hw:0,0). SDL must not go looking for a sound server that is not there.
export SDL_AUDIODRIVER=alsa

mkdir -p "$LOGS_PATH" "$SAVES_PATH" "$SHARED_USERDATA_PATH/.minui" "$USERDATA_PATH" 2>/dev/null
LOG="$LOGS_PATH/launch.txt"
: > "$LOG" 2>/dev/null

# --- clock: the board has no battery-backed RTC, so a cold boot starts in 1970 ----------------
if [ "$(date +%Y)" -lt 2025 ] && [ -f "$DATETIME_PATH" ]; then
	date -s "$(cat "$DATETIME_PATH")" >/dev/null 2>&1
fi

# --- audio codec: unmute + restore the mixer baseline BEFORE the launcher reads it ------------
# minui reads the codec volume exactly once at startup. muOS restores the mixer in a BACKGROUNDED
# pipewire.sh, which races that read and loses often enough to boot dead silent (found live
# 2026-08-06). Do it here, synchronously, before anything reads. Absent on a non-muOS OS layer,
# which is fine: alsactl restore with no state file is a no-op.
for _st in /opt/muos/device/control/asound.state /var/lib/alsa/asound.state; do
	[ -f "$_st" ] && { alsactl -U -f "$_st" restore >/dev/null 2>&1; break; }
done

# Re-assert the USER's saved volume over that baseline, at every process boundary below. The only
# muter is PWR_enterSleep (raw 0) and its un-mute lives in the SAME process; if that process is
# replaced while muted (faux-sleep then relaunch, a crash, a dev deploy) nobody writes the level
# back and the codec stays at 0 into the next game. Captured live 2026-08-10.
VOL_FILE="$USERDATA_PATH/volume"   # UI 0-20, written by libmsettings SetVolume
apply_volume() {
	[ -f "$VOL_FILE" ] || return 0
	_ui=$(cat "$VOL_FILE" 2>/dev/null)
	case "$_ui" in ''|*[!0-9]*) return 0 ;; esac   # ignore a garbage or partial file
	[ "$_ui" -gt 20 ] && _ui=20
	amixer -c 0 sset 'digital volume' $(( _ui * 63 / 20 )) >/dev/null 2>&1   # UI 0-20 -> raw 0-63
}
apply_volume

# --- the thesis: own the governor. schedutil, and minui/minarch write the ceiling on top -------
echo schedutil > /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null
echo "governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)" >> "$LOG"

# --- wifi + ssh, opt-in, and portable across OS layers -------------------------------------------
# THIS LIVES HERE, NOT IN THE OS LAYER. It used to sit in the OS-side minui-frontend.sh, which meant
# a rootfs that did not ship that script had no networking at all and, worse, no ssh, which is the
# only diagnostic when a boot fails on a device whose kernel has no framebuffer console. Keeping it
# on the card also means it works unchanged on any OS layer, since wifi.txt lives on the card too.
#
# Credentials are USER-SUPPLIED and never baked into an image: wifi.txt at the card root, one
# "SSID:password" line, # comments. No wifi.txt means none of this runs and the radio stays down,
# which is the efficient default MinUI wants anyway.
WIFI_TXT="$SDCARD_PATH/wifi.txt"
( if [ -f "$WIFI_TXT" ]; then
	_line=$(sed '/^#/d;/^[[:space:]]*$/d' "$WIFI_TXT" | head -1)
	_ssid=${_line%%:*}; _psk=${_line#*:}
	if [ -n "$_ssid" ] && [ "$_ssid" != "$_line" ]; then
		if [ -x /opt/muos/script/system/network.sh ] && [ -f /opt/muos/script/var/func.sh ]; then
			# muOS layer: delegate to its proven bring-up (driver load, scan, wpa_passphrase, dhcp,
			# validate, keepalive with the rtw_power_mgnt=0 idle-drop fix). Hand-rolling this is what
			# broke wifi repeatedly, so on that layer we do not.
			( . /opt/muos/script/var/func.sh
			  SET_VAR "config" "network/ssid"   "$_ssid"
			  SET_VAR "config" "network/pass"   "$_psk"
			  SET_VAR "config" "network/hidden" "0"
			  SET_VAR "config" "network/type"   "0"
			  SET_VAR "config" "settings/network/con_retry"  "3"
			  SET_VAR "config" "settings/network/monitor"    "1" )
			/opt/muos/script/system/network.sh connect >> "$LOG" 2>&1 &
		else
			# Bare OS layer: wpa_supplicant directly. The module is already loaded by rcS when
			# wifi.txt exists, so the interface should be present; wait briefly rather than assume.
			for _i in 1 2 3 4 5 6 7 8 9 10; do
				[ -d /sys/class/net/wlan0 ] && break
				sleep 1
			done
			ifconfig wlan0 up 2>/dev/null
			_conf=/tmp/wpa.conf
			{ echo "ctrl_interface=/var/run/wpa_supplicant"
			  echo "network={"
			  echo "	ssid=\"$_ssid\""
			  echo "	psk=\"$_psk\""
			  echo "}"; } > "$_conf"
			chmod 600 "$_conf"
			wpa_supplicant -B -i wlan0 -c "$_conf" >> "$LOG" 2>&1
			# udhcpc, not dhcpcd: busybox provides it and it is already in the rootfs.
			udhcpc -i wlan0 -b -q >> "$LOG" 2>&1 &
		fi
		# RECONNECT MONITOR. The bring-up is one-shot on both layers, and one bad roll on early boot
		# left the device offline until the next reboot (seen live 2026-08-10). NOTE: ifconfig, not
		# `ip`: this busybox has no ip applet (verified 2026-08-27), so the old check silently
		# succeeded forever and the monitor never fired.
		( _down=0
		  # Boot receipt, DEV CARDS ONLY (devmode.txt at the card root): kernel seconds at menu launch,
# one ~40-byte line per boot. Measured the fleet for the README table (2026-08-31); stays as a
# regression canary on dev cards and costs users nothing.
[ -f "$SDCARD_PATH/devmode.txt" ] && echo "$(cut -d" " -f1 /proc/uptime) menu-ready $(date +%Y-%m-%d 2>/dev/null)" >> "$LOGS_PATH/boot-time.txt"
while : ; do
			sleep 45
			[ -f "$WIFI_TXT" ] || continue
			if ifconfig wlan0 2>/dev/null | grep -q "inet addr"; then _down=0; continue; fi
			_down=$((_down + 1))
			if [ "$_down" -ge 2 ]; then
				echo "wifi monitor: offline, retrying" >> "$LOG"
				if [ -x /opt/muos/script/system/network.sh ]; then
					/opt/muos/script/system/network.sh connect >> "$LOG" 2>&1
				else
					udhcpc -i wlan0 -b -q >> "$LOG" 2>&1
				fi
				_down=0
			fi
		  done ) &
	fi
  fi
  # SSH via dropbear, key-auth only. A release image ships no key, so this is opt-in exactly like
  # wifi: drop your public key at the card root as authorized_keys. The card is the only writable
  # surface a user has before ssh works, so requiring them to edit /root/.ssh first is a
  # chicken-and-egg. No key means no daemon at all rather than an idle listening port.
  mkdir -p /root/.ssh 2>/dev/null
  [ -s "$SDCARD_PATH/authorized_keys" ] && cp "$SDCARD_PATH/authorized_keys" /root/.ssh/authorized_keys 2>/dev/null
  chmod 700 /root/.ssh 2>/dev/null; chmod 600 /root/.ssh/authorized_keys 2>/dev/null
  DBM="$SYSTEM_PATH/bin/dropbearmulti"
  DBKEY="$USERDATA_PATH/dropbear_ed25519_host_key"
  if [ -x "$DBM" ] && [ -s /root/.ssh/authorized_keys ] && ! pgrep dropbearmulti >/dev/null 2>&1; then
	[ -f "$DBKEY" ] || "$DBM" dropbearkey -t ed25519 -f "$DBKEY" 2>/dev/null
	"$DBM" dropbear -r "$DBKEY" -p 22 2>/dev/null
	# STAY AWAKE while SSH is up (Dan, 2026-09-08). The h700 has no deep sleep, so MinUI's idle
	# escalation POWERS IT OFF after ~2 min, which killed every remote debug session. STAY_AWAKE_PATH
	# is honored by PWR_preventAutosleep (shared api.c), and blocking autosleep also blocks that
	# power-off. Only reached when a key is present, i.e. the user opted into SSH; a release image
	# ships no key and never touches this.
	touch /tmp/stay_awake 2>/dev/null
  fi
  echo "net: $(ifconfig wlan0 2>/dev/null | sed -n 's/.*inet addr:\([0-9.]*\).*/\1/p') ssh=$(pgrep dropbearmulti >/dev/null && echo up || echo down) awake=$([ -f /tmp/stay_awake ] && echo y || echo n)" >> "$LOG"
) &

# --- boot-time readahead ----------------------------------------------------------------------
# The FIRST launch after a boot is the slow one: everything it touches is cold on a ~10MB/s card.
# MEASURED 2026-08-10: 4348ms cold vs 707ms warm. Pull that fixed cost into the seconds after boot
# while the user is reading the menu. Page cache only: nothing stays resident, the kernel evicts
# under pressure, and it costs nothing the thesis measures.
#
# NOT libmali.so (42.5MB): it was in this list on the assumption SDL dlopens it, but we run with
# SDL_VIDEODRIVER=dummy, that driver is absent from this SDL build, video init fails and we present
# through the DE hardware scaler. VERIFIED on-device 2026-08-26 in both the menu and a running game:
# no libmali/EGL/GLES mapping, no /dev/mali0 fd. Reading it was pure waste at every boot.
( nice -n 19 sh -c '
	sleep 3
	for f in /usr/lib/libSDL2-2.0.so.0 /usr/lib/libSDL2_image-2.0.so.0 \
	         /usr/lib/libSDL2_ttf-2.0.so.0 "$SYSTEM_PATH/bin/minarch.elf" \
	         "$SYSTEM_PATH/lib/libmsettings.so"; do
		[ -f "$f" ] && cat "$f" > /dev/null 2>&1
	done
	R="$SHARED_USERDATA_PATH/.minui/recent.txt"
	if [ -f "$R" ]; then
		T=$(sed -n "1p" "$R" | sed -n "s/.*(\([A-Z0-9]*\)).*/\1/p")
		[ -n "$T" ] && [ -f "$SYSTEM_PATH/paks/Emus/$T.pak/launch.sh" ] && \
			C=$(grep -o "[a-z0-9_-]*_libretro\.so" "$SYSTEM_PATH/paks/Emus/$T.pak/launch.sh" | head -1) && \
			[ -n "$C" ] && [ -f "$CORES_PATH/$C" ] && cat "$CORES_PATH/$C" > /dev/null 2>&1
	fi
' >/dev/null 2>&1 ) &

# --- community pak compat ---------------------------------------------------------------------
# The scene's canonical mount is /mnt/SDCARD and paks hardcode it constantly (NextUI HOOKS.md
# documents that literal path). Ours is elsewhere, so a hardcoded pak would write into a
# nonexistent tree and silently do nothing. Only when the real mount exists and the name is free.
[ -d "$SDCARD_PATH" ] && [ ! -e /mnt/SDCARD ] && ln -s "$SDCARD_PATH" /mnt/SDCARD 2>/dev/null

# --- power off ---------------------------------------------------------------------------------
# The AXP register write is how this board actually powers down; a plain poweroff reboots it.
power_off() {
	sync
	echo 0x1801 > /sys/class/axp/axp_reg 2>/dev/null
	[ -x /opt/muos/script/system/halt.sh ] && /opt/muos/script/system/halt.sh poweroff 2>/dev/null
	poweroff -f
}

# --- boot straight into the game ---------------------------------------------------------------
# MinUI quicksaves on power-off and resumes on the next boot, but the resume normally goes through
# the launcher: it starts, reads the marker, writes /tmp/next and exits, so a resume pays a full
# launcher startup and a menu frame the user never wanted. Do it here instead.
#
# The contract is the launcher's own (minui.c autoResume): the marker holds a card-relative rom
# path, it is consumed EXACTLY ONCE (unlink before launching, so a crash cannot resume-loop), and
# slot 9 tells minarch to load the auto-save. Every failure falls through to the normal path.
AUTO_RESUME="$SHARED_USERDATA_PATH/.minui/auto_resume.txt"
if [ -f "$AUTO_RESUME" ]; then
	_rel=$(head -1 "$AUTO_RESUME" 2>/dev/null)
	rm -f "$AUTO_RESUME"; sync
	_rom="$SDCARD_PATH$_rel"
	_tag=$(dirname "$_rel" | sed -n 's/.*(\([A-Za-z0-9]*\))$/\1/p')
	_pak="$SYSTEM_PATH/paks/Emus/$_tag.pak/launch.sh"
	if [ -n "$_rel" ] && [ -f "$_rom" ] && [ -n "$_tag" ] && [ -f "$_pak" ]; then
		echo "boot-to-game: $_tag <- $_rel" >> "$LOG"
		echo 9 > /tmp/resume_slot.txt
		apply_volume
		sh "$_pak" "$_rom" >> "$LOG" 2>&1
		[ -f /tmp/poweroff ] && { echo "poweroff requested (boot-to-game)" >> "$LOG"; power_off; }
	fi
fi

AUTO_PATH="$USERDATA_PATH/auto.sh"
[ -f "$AUTO_PATH" ] && "$AUTO_PATH"

cd "$(dirname "$0")"

#######################################

# THE LAUNCH LOOP. Ported verbatim from the h700 frontend script rather than from tg5040, because
# the two platforms genuinely differ and the h700 semantics are the audited ones:
#   - tg5040 ends the loop by unlinking /tmp/minui_exec in PLAT_powerOff.
#   - h700 PLAT_powerOff drops /tmp/poweroff instead, so the loop can tell a real power-off request
#     from an ordinary game or menu exit. Without that distinction an in-game power-off looked like
#     a quit and relaunched the same game (audit 2026-08-07).
# A first draft of this file used the tg5040 marker, which would have left the power-off path
# working only by accident and dropped the fail-retry below entirely (caught 2026-08-26).
FAILS=0
# WiFi Toggle visibility (Dan, 2026-08-31): the tool appears in Tools ONLY when wifi is
# configured — wifi.txt (on) or wifi.txt.off (toggled off; must stay visible or there is no way
# back on). Unconfigured cards keep a clean Tools menu; the pak ships stashed in .system so
# updates always carry it, and this block is the sole owner of the Tools copy. Deploys that
# prune the Tools copy are self-healing: the next boot re-copies it.
WIFI_PAK_SRC="$SYSTEM_PATH/paks/tools-stash/WiFi Toggle.pak"
WIFI_PAK_DST="$SDCARD_PATH/Tools/h700/WiFi Toggle.pak"
if [ -f "$SDCARD_PATH/wifi.txt" ] || [ -f "$SDCARD_PATH/wifi.txt.off" ]; then
	[ -d "$WIFI_PAK_DST" ] || cp -r "$WIFI_PAK_SRC" "$WIFI_PAK_DST" 2>/dev/null
else
	rm -rf "$WIFI_PAK_DST" 2>/dev/null
fi
while : ; do
	rm -f /tmp/next /tmp/poweroff
	minui.elf >> "$LOG" 2>&1
	RC=$?
	[ -f /tmp/poweroff ] && { echo "poweroff requested" >> "$LOG"; power_off; }
	if [ -f /tmp/next ]; then
		FAILS=0
		CMD=$(cat /tmp/next)
		echo "launch: $CMD" >> "$LOG"
		apply_volume   # a mute left behind by the menu process must not follow us into the game
		sh -c "$CMD"
		echo "game exited rc=$?" >> "$LOG"
		apply_volume   # ...nor back into the menu if the game was killed while muted
		[ -f /tmp/poweroff ] && { echo "poweroff requested (in-game)" >> "$LOG"; power_off; }
		echo "$(date +'%F %T')" > "$DATETIME_PATH"
		sync
	elif [ "$RC" = "0" ]; then
		echo "clean exit, power off" >> "$LOG"
		power_off
	else
		FAILS=$((FAILS+1))
		echo "minui exited rc=$RC (fail $FAILS)" >> "$LOG"
		# Retry so transient faults self-heal; persistent failure powers OFF rather than parking in
		# an infinite sleep, which left a black, draining, unrecoverable device (audit).
		[ $FAILS -ge 5 ] && { echo "$FAILS consecutive fails, powering off" >> "$LOG"; power_off; }
		sleep 2
	fi
done
