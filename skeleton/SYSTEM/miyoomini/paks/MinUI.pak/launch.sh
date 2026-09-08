#!/bin/sh
# MiniUI.pak

if [ -z "$LCD_INIT" ]; then
	# an update may have already initilized the LCD
	/mnt/SDCARD/.system/miyoomini/bin/blank.elf

	# init backlight
	echo 0 > /sys/class/pwm/pwmchip0/export
	echo 800 > /sys/class/pwm/pwmchip0/pwm0/period
	echo 6 > /sys/class/pwm/pwmchip0/pwm0/duty_cycle
	echo 1 > /sys/class/pwm/pwmchip0/pwm0/enable

	# init lcd
	cat /proc/ls
	sleep 0.5
fi

# init charger detection
if [ ! -f /sys/devices/gpiochip0/gpio/gpio59/direction ]; then
	echo 59 > /sys/class/gpio/export
	echo in > /sys/devices/gpiochip0/gpio/gpio59/direction
fi


#######################################

if [ -f /customer/app/axp_test ]; then
	IS_PLUS=true
else
	IS_PLUS=false
fi
export IS_PLUS

# IS_PLUS IS NOT "IS THE MINI PLUS". The Mini FLIP also ships /customer/app/axp_test — Allium routes
# the Flip and the Plus to the SAME AXP battery implementation (Miyoo285 | Miyoo354 =>
# Miyoo354Battery), and that implementation shells out to axp_test, so the file must be present on a
# Flip. IS_PLUS therefore means "has the AXP PMIC", which is what the battery code wants and is NOT
# a model identity.
#
# Anything keyed to the PLUS SPECIFICALLY must exclude the Flip, and the hall sensor is the test:
# it is the clamshell lid, present only on the Flip, and five independent sources agree on the path
# (ours, upstream MinUI, MyMinUI, spruceOS's MiyooMini.sh, Allium's evdev.rs).
#
# MY_MODEL would be the obvious discriminator but is not resolved until much later in this file.
if [ -e /sys/devices/soc0/soc/soc:hall-mh248/hallvalue ]; then
	IS_FLIP=true
else
	IS_FLIP=false
fi
export IS_FLIP

export PLATFORM="miyoomini"
export SDCARD_PATH="/mnt/SDCARD"
export BIOS_PATH="$SDCARD_PATH/Bios"
export SAVES_PATH="$SDCARD_PATH/Saves"
export SYSTEM_PATH="$SDCARD_PATH/.system/$PLATFORM"
export CORES_PATH="$SYSTEM_PATH/cores"

# PANEL REFRESH — PER MODEL, and only ever a MEASURED one.
#
# The Mini Plus panel's true refresh is 59.6720 Hz. MEASURED DIRECTLY with tools/panelprobe.c (tight
# page-flip loop, no emulator/audio/scaler, CLOCK_MONOTONIC in-process; three runs agreed to four
# decimals). Corroborated at 59.6873 Hz by timing 120 FBIO_WAITFORVSYNC calls. minarch derives a
# per-core correction from it: NES/SNES -7102ppm, GB/GBC/GBA -929, Genesis -4184, PS1 -4471.
#
# THIS REQUIRES the page-ownership state machine in platform.c (flip_front/active/pending/rendering).
# Enabling the rate match without it caused visible TEARING, twice: matching the producer to the
# panel stops the phase drifting, so the front-page race went from rare to every frame. The producer
# used to guard only against `active` and `pending` — nothing tracked the page being scanned out.
#
# WHY THIS IS GATED. The value above is a property of ONE panel, on the one model we own. The
# original Mini and the Mini Flip ship the same binaries but nobody has measured their panels, and
# an unmeasured rate is worse than none: minarch would pull every core toward a number we invented.
# Leaving it unset costs those models nothing they had before — no rate match is exactly the
# pre-v1.5.4 behaviour. To add a model, run tools/panelprobe.c ON IT and put the result here; do not
# copy the Plus's figure across on the assumption that one SSD202D panel is another.
# Gated on the PLUS specifically, not merely on having an AXP: the Flip sets IS_PLUS too (see the
# note where IS_FLIP is derived), and handing a Flip the Plus's measured figure is exactly the
# invented-number hazard this gate exists to prevent. Its panel has never been measured.
if [ "$IS_PLUS" = "true" ] && [ "$IS_FLIP" != "true" ]; then
	export MINARCH_PANEL_FPS=59.6720
	# ZERO_AUDIO_SERVO deliberately NOT exported here (tg5040 only for now): the occupancy servo
	# trims the resampler on top of this match and is unmeasured on the MI_AO/preload audio
	# path. Ear-check on this device before arming (earned divergence, 2026-09-02).
fi
export USERDATA_PATH="$SDCARD_PATH/.userdata/$PLATFORM"
export SHARED_USERDATA_PATH="$SDCARD_PATH/.userdata/shared"
export LOGS_PATH="$USERDATA_PATH/logs"
export DATETIME_PATH="$SHARED_USERDATA_PATH/datetime.txt" # used by bin/shutdown

mkdir -p "$USERDATA_PATH"
mkdir -p "$LOGS_PATH"
mkdir -p "$SHARED_USERDATA_PATH/.minui"

#######################################

# The closed-loop governor owns the clock during gameplay (userspace + scaling_setspeed).
# These stay for the menu//tmp/next path, but note 1296/1488 exceed the top STOCK OPP (1200) --
# overclock.elf reaches them by poking the MPLL directly, which we do not do. Menu runs at a
# real OPP instead.
# OPT-IN shell-side boot timing (ZERO_BOOT_TIMING=1), same switch minui.elf uses for its own
# startup probes. /proc/uptime is monotonic seconds since kernel start, so these stamps line up
# with the kernel's own clock and cost one read each. Off by default: this writes to the SD card.
bt() { [ "$ZERO_BOOT_TIMING" = "1" ] && echo "$(cut -d' ' -f1 /proc/uptime) $1" >> /mnt/SDCARD/boot-timing.txt; }
bt "launch.sh start"
# Boot receipt, DEV CARDS ONLY (devmode.txt at the card root): kernel seconds at menu launch,
# one ~40-byte line per boot. Measured the fleet for the README table (2026-08-31); stays as a
# regression canary on dev cards and costs users nothing.
[ -f "$SDCARD_PATH/devmode.txt" ] && echo "$(cut -d" " -f1 /proc/uptime) menu-ready $(date +%Y-%m-%d 2>/dev/null)" >> "$LOGS_PATH/boot-time.txt"

# WIFI OPT-IN — the same one visible wifi.txt at the card root as TrimUI and Anbernic.
# PORTED 2026-08-31 after learning the hard way: the MMP's wifi previously came from an ad-hoc
# community pak that lived ONLY on the card, so the first clean update deleted it and the device
# silently lost networking (Dan's card, tonight). This block is the in-repo replacement. The
# command sequence is not guessed: it is reconstructed from the old pak's own set-x trace, which
# survived in .userdata/miyoomini/logs/Wifi.on-boot.txt on that card.
# Stock internal binaries do the work (/customer/app/*); only the 8188fu kernel module has no
# certain internal home — we try the known candidates and log a probe when all miss.
if [ -f "$SDCARD_PATH/wifi.txt" ]; then
	_w=$(sed '/^#/d;/^[[:space:]]*$/d' "$SDCARD_PATH/wifi.txt" | head -1)
	_ssid=${_w%%:*}; _psk=${_w#*:}
	if [ -n "$_ssid" ] && [ "$_ssid" != "$_w" ]; then
		WLOG="$LOGS_PATH/wifi.txt.log"
		{
		echo "== wifi.txt bring-up $(date 2>/dev/null)"
		# stock config: wpa_supplicant.conf lives in the console's internal /appconfigs
		printf 'ctrl_interface=/var/run/wpa_supplicant\nupdate_config=1\nnetwork={\n\tssid="%s"\n\tpsk="%s"\n}\n' "$_ssid" "$_psk" > /appconfigs/wpa_supplicant.conf
		# driver module: card ship first (if we ever bundle one), then stock candidates
		if ! grep -q 8188fu /proc/modules 2>/dev/null; then
			for KO in "$SYSTEM_PATH/lib/modules/8188fu.ko" /config/wifi/8188fu.ko /customer/wifi/8188fu.ko /lib/modules/8188fu.ko; do
				[ -f "$KO" ] && { insmod "$KO"; echo "insmod $KO rc=$?"; break; }
			done
		fi
		if ! grep -q 8188fu /proc/modules 2>/dev/null; then
			echo "PROBE: no 8188fu.ko found; candidates on this console:"
			find /config /customer /lib -name "*8188*" 2>/dev/null
		fi
		# power + interface + supplicant, straight from the old pak's trace
		ifconfig lo up 2>/dev/null
		/customer/app/axp_test wifion
		sleep 2
		ifconfig wlan0 up
		killall wpa_supplicant 2>/dev/null; killall udhcpc 2>/dev/null
		/customer/app/wpa_supplicant -B -D nl80211 -iwlan0 -c /appconfigs/wpa_supplicant.conf
		udhcpc -i wlan0 -t 8 -T 3 -b 2>/dev/null &
		command -v iw >/dev/null 2>&1 && iw dev wlan0 set power_save off 2>/dev/null
		} >> "$WLOG" 2>&1 &
	fi
fi

# DEV-ONLY SSH (Dan, 2026-09-07). Gated on devmode.txt at the card root, exactly like the boot
# receipt above, so a user card NEVER starts a daemon — this fork stays runs-cold and radio-quiet.
# WHY THIS EXISTS: the MMP's ssh used to come from an ad-hoc community pak that lived only on the
# card (same pak as the old wifi bring-up). The first clean update deleted it, wifi survived because
# 2026-08-31 absorbed that half into this file, and ssh did not because we never absorbed this half.
# The result was a device that could be updated ONLY by card reader, which cost a whole evening.
# Requires wifi.txt too: without a network there is nothing to listen on.
# Host keys live on the CARD (.userdata/miyoomini/SSH), so they survive updates and the device keeps
# one identity — the orphaned keys the old pak left there are reused rather than regenerated.
# INSTRUMENTATION (2026-09-08): on the first boot of this block it produced NO output whatsoever —
# not even its own first line — with both gate files verified present on the card afterwards. The
# block re-runs correctly under real busybox ash, so the failure is in reaching it, not in it. This
# one line fires on the SAME gate as the boot receipt above (which demonstrably does fire), so the
# next boot separates the three cases instead of costing another evening: line present + "devmode
# ssh" present = the block ran; line present, no "devmode ssh" = a gate was false and it names
# which; NEITHER line = the launcher that ran is not the file on the card.
[ -f "$SDCARD_PATH/devmode.txt" ] && echo "reached ssh gate $(date 2>/dev/null) devmode=y wifi=$([ -f "$SDCARD_PATH/wifi.txt" ] && echo y || echo n)" >> "$LOGS_PATH/ssh-boot.txt"
if [ -f "$SDCARD_PATH/devmode.txt" ] && [ -f "$SDCARD_PATH/wifi.txt" ]; then
	SSH_DIR="$USERDATA_PATH/SSH"
	# NOT "ssh.txt": the old community pak left an SSH.txt in this same directory, and vfat lookups
	# are case-insensitive, so the two names are ONE file on the device — which made the old pak's
	# 2025 trace look like ours and cost real time to untangle. A distinct name keeps them apart.
	SSH_LOG="$LOGS_PATH/ssh-boot.txt"
	mkdir -p "$SSH_DIR" "$LOGS_PATH" 2>/dev/null
	{
	echo "== devmode ssh $(date 2>/dev/null)"
	# key auth: drop authorized_keys at the card root (or in the SSH dir) and it is installed here.
	for AK in "$SDCARD_PATH/authorized_keys" "$SSH_DIR/authorized_keys"; do
		[ -f "$AK" ] || continue
		mkdir -p /root/.ssh 2>/dev/null
		cp "$AK" /root/.ssh/authorized_keys 2>/dev/null \
			&& { chmod 700 /root/.ssh 2>/dev/null; chmod 600 /root/.ssh/authorized_keys 2>/dev/null; echo "authorized_keys installed from $AK"; } \
			|| echo "authorized_keys FAILED to install from $AK (is /root writable?)"
		break
	done
	HK="$SSH_DIR/dropbear_ed25519_host_key"
	STARTED=0
	# 1) the console's own dropbear, if this firmware has one. -R lets it make its own host key when
	#    ours is absent; we pass -r first so the identity stays stable across updates.
	for DB in /customer/app/dropbear /usr/sbin/dropbear /usr/bin/dropbear /bin/dropbear /mnt/SDCARD/miyoo/app/dropbear; do
		[ -x "$DB" ] || continue
		# stderr is NOT suppressed: a missing shared library is the likeliest failure and only
		# dropbear's own message names it.
		if [ -f "$HK" ]; then "$DB" -r "$HK" -p 22; else "$DB" -R -p 22; fi
		sleep 1
		pgrep dropbear >/dev/null 2>&1 && { echo "started $DB on :22"; STARTED=1; break; }
	done
	# 2) a dropbearmulti we ship for THIS architecture, if one is ever added. The tg5040 binary in
	#    .system/tg5040/bin is aarch64 and cannot run here, so only the miyoomini path is tried.
	if [ "$STARTED" != 1 ]; then
		DBM="$SYSTEM_PATH/bin/dropbearmulti"
		if [ -x "$DBM" ]; then
			[ -f "$HK" ] || "$DBM" dropbearkey -t ed25519 -f "$HK"
			"$DBM" dropbear -r "$HK" -p 22
			sleep 1
			pgrep dropbear >/dev/null 2>&1 && { echo "started shipped dropbearmulti on :22"; STARTED=1; }
		fi
	fi
	# 3) no daemon anywhere: say so loudly and record what this console actually has, so the next
	#    boot answers the question instead of another evening of port scans (same probe pattern as
	#    the 8188fu module hunt above).
	if [ "$STARTED" != 1 ]; then
		echo "NO SSH DAEMON STARTED — nothing will be listening."
		echo "PROBE: dropbear/ssh binaries present on this console:"
		find /customer /usr /bin /sbin /mnt/SDCARD/miyoo -name '*dropbear*' -o -name 'sshd' 2>/dev/null | head -20
		echo "PROBE: end. If this list is empty we must ship an armhf dropbearmulti."
	fi
	echo "ip: $(ip -4 addr show wlan0 2>/dev/null | sed -n 's/.*inet \([0-9.]*\).*/\1/p' | head -1)"
	} >> "$SSH_LOG" 2>&1 &
fi

# WiFi Toggle visibility (Dan, 2026-08-31): the tool appears in Tools ONLY when wifi is
# configured — wifi.txt (on) or wifi.txt.off (toggled off; must stay visible or there is no way
# back on). Unconfigured cards keep a clean Tools menu; the pak ships stashed in .system so
# updates always carry it, and this block is the sole owner of the Tools copy. Deploys that
# prune the Tools copy are self-healing: the next boot re-copies it.
WIFI_PAK_SRC="$SYSTEM_PATH/paks/tools-stash/WiFi Toggle.pak"
WIFI_PAK_DST="$SDCARD_PATH/Tools/miyoomini/WiFi Toggle.pak"
if [ -f "$SDCARD_PATH/wifi.txt" ] || [ -f "$SDCARD_PATH/wifi.txt.off" ]; then
	[ -d "$WIFI_PAK_DST" ] || cp -r "$WIFI_PAK_SRC" "$WIFI_PAK_DST" 2>/dev/null
else
	rm -rf "$WIFI_PAK_DST" 2>/dev/null
fi

# SSH visibility, DEV CARDS ONLY (Dan, 2026-09-08: "We should do that and enable with devmode").
# Same stash/copy pattern as WiFi Toggle above, but gated on devmode.txt so a user card never gets
# a way to start a daemon. This is the on-demand twin of the boot block earlier in this file, and
# it follows Onion's shape (SSH as a toggle you press, wifi-gated) rather than inventing one — see
# the pak's own header. A dev card that has never had devmode.txt simply never sees it.
SSH_PAK_SRC="$SYSTEM_PATH/paks/tools-stash/SSH.pak"
SSH_PAK_DST="$SDCARD_PATH/Tools/miyoomini/SSH.pak"
if [ -f "$SDCARD_PATH/devmode.txt" ]; then
	[ -d "$SSH_PAK_DST" ] || cp -r "$SSH_PAK_SRC" "$SSH_PAK_DST" 2>/dev/null
else
	rm -rf "$SSH_PAK_DST" 2>/dev/null
fi


export CPU_SPEED_MENU=600000
export CPU_SPEED_GAME=1200000
export CPU_SPEED_PERF=1200000
echo userspace > /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
echo $CPU_SPEED_MENU > /sys/devices/system/cpu/cpufreq/policy0/scaling_setspeed 2>/dev/null

# `strings` over the 1.4MB vendor MainUI binary costs a MEASURED 130ms on every single boot, and
# the answer cannot change without a firmware reflash. Cache it. (Same fix as the tg5040
# model-detect cache.) Delete $USERDATA_PATH/model.txt to force a re-probe.
MODEL_CACHE="$USERDATA_PATH/model.txt"
if [ -s "$MODEL_CACHE" ]; then
	export MY_MODEL=`cat "$MODEL_CACHE"`
else
	export MY_MODEL=`strings -n 5 /customer/app/MainUI | grep MY`
	echo "$MY_MODEL" > "$MODEL_CACHE"
fi

MIYOO_VERSION=`/etc/fw_printenv miyoo_version`
export MIYOO_VERSION=${MIYOO_VERSION#miyoo_version=}

#######################################

# killall tee # NOTE: killing tee is somehow responsible for audioserver crashes
rm -f "$SDCARD_PATH/update.log"

#######################################

export LD_LIBRARY_PATH=$SYSTEM_PATH/lib:$LD_LIBRARY_PATH
export PATH=$SYSTEM_PATH/bin:$PATH

#######################################

# AUDIO: one system-lifetime codec owner.
#
# Every pop on this device is an MI_AO power transition -- boot enable, per-game enable/disable,
# poweroff. Muting cannot hide one: MI_AO_SETMUTE gates the DATA path only (proven on device --
# muting never fixed the exit pop; not calling MI_AO_Disable did). One long-lived owner means the
# codec powers up once and never cycles, so the game-boundary pops have nothing to fire on.
#
# SDL2 uses its STOCK OSS backend (src/audio/dsp), selected per-game with SDL_AUDIODRIVER=dsp,
# and libpadsp redirects /dev/dsp into audioserver. This is what MyMinUI actually ships; their
# other/sdl2.patch is an unused draft and applying it here broke game launch.
# The Mini PLUS uses the STOCK /customer/app/audioserver (audioserver.mod is the non-Plus path).
AUDIO_SHIM=/customer/lib/libpadsp.so
AUDIO_FIFO=/tmp/audio_fifo_server

# Is the daemon USABLE right now? Every condition is checked at the moment of use, never cached:
# a boot-time verdict goes stale the instant the daemon dies, and acting on a stale one forces
# games onto a dead OSS path, which is silence.
audio_daemon_ok() {
	# Plus ONLY. The stock /customer/app/audioserver is the qualified path for THIS model; other
	# Miyoo models use audioserver.mod, which is not qualified here. Testing for the binary is not
	# enough -- keep everything else on explicit direct MMIYOO.
	#
	# The Flip must be EXCLUDED explicitly: it ships /customer/app/axp_test too, so IS_PLUS is true
	# there. IS_PLUS means "has the AXP PMIC", not "is the Plus" — see where IS_FLIP is derived.
	# Without this a Flip that happens to have the daemon, shim and FIFO would be routed through an
	# audio path nobody has qualified on that hardware.
	[ "$IS_PLUS" = "true" ] || return 1
	[ "$IS_FLIP" != "true" ] || return 1
	[ -x /customer/app/audioserver ] || return 1
	# The client shim is what actually routes /dev/dsp into the daemon. Without it, selecting the
	# OSS driver just opens the raw device and the game is silent.
	[ -f "$AUDIO_SHIM" ] || return 1
	pgrep audioserver >/dev/null 2>&1 || return 1
	[ -e "$AUDIO_FIFO" ] || return 1
	return 0
}

# Bring the daemon up and WAIT until it is genuinely serving. Bounded (~5s) so a broken daemon can
# never hang the launcher; returns non-zero instead, and the caller falls back.
audio_daemon_start() {
	[ "$IS_PLUS" = "true" ] || return 1
	[ "$IS_FLIP" != "true" ] || return 1   # Flip has axp_test too; see audio_daemon_ok
	[ -x /customer/app/audioserver ] || return 1
	# Check the CLIENT SHIM *before* spawning anything. Without libpadsp we cannot route games to
	# the daemon — but a spawned daemon would still CLAIM MI_AO, and then the direct-MMIYOO fallback
	# could not open the codec and the game would be silent. Never start an owner we cannot use.
	[ -f "$AUDIO_SHIM" ] || return 1
	if ! pgrep audioserver >/dev/null 2>&1; then
		# The FIFOs OUTLIVE the daemon (measured: SIGKILL it and /tmp/audio_fifo_server is still
		# there). A leftover would make readiness pass instantly against a daemon that has not
		# started serving yet. Safe to remove -- nothing owns them when no daemon is running.
		rm -f /tmp/audio_fifo_server /tmp/audio_fifo_ioctl_req /tmp/audio_fifo_ioctl_res
		# idempotent: this branch only runs when no owner exists, so we never stack a second one
		/customer/app/audioserver -60 &
	fi
	i=0
	while [ $i -lt 50 ]; do
		audio_daemon_ok && return 0
		sleep 0.1
		i=$((i+1))
	done
	return 1
}

# Release the codec from a daemon we are NOT going to use. A daemon that is alive but not serving
# (no FIFO, or no shim to reach it with) still OWNS MI_AO, so handing the device to a direct-MMIYOO
# game would leave that game unable to open the codec — silent, with nothing in the logs to say why.
# Stop it and confirm it is gone before selecting direct audio.
audio_daemon_release() {
	pgrep audioserver >/dev/null 2>&1 || return 0
	killall audioserver 2>/dev/null
	i=0
	while [ $i -lt 20 ]; do
		pgrep audioserver >/dev/null 2>&1 || break
		sleep 0.1
		i=$((i+1))
	done
	pgrep audioserver >/dev/null 2>&1 && killall -9 audioserver 2>/dev/null
	sleep 0.3
	# its FIFOs outlive it; leave nothing that could later look like readiness
	rm -f /tmp/audio_fifo_server /tmp/audio_fifo_ioctl_req /tmp/audio_fifo_ioctl_res
	pgrep audioserver >/dev/null 2>&1 && return 1
	return 0
}

#######################################

bt "lumon"
lumon.elf & # adjust lcd luma and saturation

# Restore the USER's brightness before the charge screen.
#
# LCD init above parks the backlight at duty 6 — the value SetBrightness(0) maps to, i.e. the
# dimmest step — and the saved level is only applied later by keymon's InitSettings(). batmon runs
# in between, so it both DREW and RESTORED at duty 6: plugging in a powered-off device showed the
# battery screen as dim as the panel goes, whatever the user had set.
#
# Brightness only, deliberately: syncsettings.elf would do this but also calls SetVolume(), which
# touches MI_AO — and audioserver has not claimed the codec yet at this point. Enabling MI_AO here
# would risk the 0xa0052009 "cannot reconfigure an enabled device" wall that stops the daemon
# starting at all. This is pure PWM sysfs and cannot interfere.
#
# msettings.bin is a struct of ints: version, brightness, headphones, speaker, jack.
# Brightness is the second, at byte offset 4. Mapping matches msettings.c SetBrightness():
# 0 -> duty 6, otherwise value*10.
MSETTINGS="$USERDATA_PATH/msettings.bin"
if [ -s "$MSETTINGS" ]; then
	B=$(od -An -tu4 -j4 -N4 "$MSETTINGS" 2>/dev/null | tr -d ' ')
	case "$B" in
		''|*[!0-9]*) B="" ;;
		*) [ "$B" -gt 10 ] && B="" ;;   # out of range: leave the boot default alone
	esac
	if [ -n "$B" ]; then
		[ "$B" = "0" ] && DUTY=6 || DUTY=$((B * 10))
		echo $DUTY > /sys/class/pwm/pwmchip0/pwm0/duty_cycle 2>/dev/null
	fi
fi

# CHARGE-ONLY MODE — deliberately the FIRST thing after backlight setup, and ahead of audioserver,
# keymon, minui, the governor and any core. Plugging in a powered-off device should light a battery
# screen, not boot a games console in the dark: nothing below this line has any business running
# while the user is only charging.
#
# Behaviour (matches the Brick/SP screen this renders):
#   POWER          -> exits, boot continues (exactly once)
#   charger pulled -> exits, boot continues  (the old one ran `shutdown` here, so unplugging
#                     powered the device off)
#   idle           -> dims only, stays responsive  (the old one blanked after 3s and blocked,
#                     which was indistinguishable from a hang and got reported as a crash twice)
#
# ONE predicate, and it lives in batmon. The launcher used to gate on `axp_test` field 7 == 3,
# which is AXP reg 0x00 BIT 2 — battery current direction. That bit CLEARS when the battery is
# full, so a plugged-in device at 100% read as "not charging" and booted straight to the menu,
# while batmon (which gates on ACIN/VBUS presence) would have stayed. Two notions of "charging" in
# two places is how that divergence survived. batmon now decides, and exits immediately when the
# device is not externally powered.
# batmon owns the decision on AXP hardware: its preflight reads the PMIC once and returns
# immediately unless external power is actually present (measured: 20 invocations on battery in 0s).
#
# But batmon is AXP-ONLY -- isPowered() is a raw i2c read with no gpio path. On the original Mini
# (no AXP) that read always fails, so "one predicate in batmon" silently meant NO CHARGE SCREEN AT
# ALL on that model, even though platform.c and keymon both read gpio59 there correctly. The gate
# below is therefore not a duplicate hardware rule, it is the non-AXP branch batmon does not have.
# Select on the AXP PMIC ITSELF, not on the presence of an i2c bus. batmon does a raw AXP read, and
# an i2c ADAPTER NODE DOES NOT PROVE THE AXP SLAVE IS PRESENT — it is a proxy for the question, not
# the question. (I have no device evidence that a Mini actually exposes /dev/i2c-1, so this is a
# correctness change on the predicate, not a fix for an observed failure.) IS_PLUS is derived from
# /customer/app/axp_test and means exactly "has the AXP", which is what is being asked here — the
# one place where its literal meaning is the right one. The Flip is deliberately NOT excluded: it
# has an AXP and wants the AXP path.
if [ "$IS_PLUS" = "true" ]; then
	batmon.elf
else
	CHARGING=`cat /sys/devices/gpiochip0/gpio/gpio59/value 2>/dev/null`
	[ "$CHARGING" = "1" ] && batmon.elf
fi

#######################################

# Audio comes up AFTER charge mode exits: a charging device needs no codec, and starting the daemon
# first would have it hold MI_AO through the whole charging session for nothing.
# Still before minui.elf, and that ordering is load-bearing: the daemon must claim MI_AO before
# anything else opens it, or MI_AO_SetPubAttr fails with 0xa0052009 and it dies. This is the only
# moment in the session when it can win the codec.
bt "audio daemon start"
audio_daemon_start
bt "audio daemon ready"
AUDIO_DAEMON=0
if audio_daemon_ok; then
	AUDIO_DAEMON=1
	AUDIO_RETRY=1   # one revival attempt is allowed if it later dies; see the launch site
else
	# Same reasoning as the per-launch fallback below, and it has to be here too: a daemon that
	# SPAWNED but never became ready is still a live process HOLDING MI_AO. Leaving it alive and
	# quietly selecting direct MMIYOO gave every game of the session a codec it could not open --
	# silence, with a healthy-looking log. Take the device back before anyone else asks for it.
	#
	# audio_daemon_release returns non-zero when the process SURVIVED even SIGKILL (or respawned).
	# Ignoring that lands us in exactly the silent-fallback state this block exists to prevent, so
	# say so loudly rather than booting into a session where no game can make a sound.
	if ! audio_daemon_release; then
		echo "ZERO: audioserver survived release — MI_AO is still held, games will be SILENT" >&2
		say.elf "audio error" 2>/dev/null || true
	fi
	# It never won the codec at boot, which is the only moment it can (see the launch site); a
	# revival attempt would stall each launch for the readiness timeout and still fail.
	AUDIO_RETRY=0
fi

# Do NOT export the shim globally. libpadsp is fragile for non-SDL clients -- a program that
# actually drives /dev/dsp segfaults under it (measured) -- and keymon, the shutdown helper and
# every other child inherit whatever is exported here. The menu plays no audio and does not need
# it; only the game process tree does (applied at the launch site below).
unset LD_PRELOAD
export AUDIO_DAEMON

bt "keymon"
keymon.elf & # &> /mnt/SDCARD/keymon.txt &

#######################################

# init datetime — RTC-FIRST on this device (inverted vs upstream, which restores from a file
# unless `enable-rtc` exists).
#
# MEASURED 2026-07-25: this board has a working battery-backed RTC and it is ACCURATE.
#   /sys/class/rtc/rtc0/time  22:16:18     <- correct to the second
#   system clock              22:11:19     <- 5 minutes behind
#   datetime.txt              22:08:32     <- what upstream's restore had written back
# Restoring from datetime.txt therefore OVERWRITES a good clock with the timestamp of the last
# shutdown, so the clock walks backwards every boot. Verified after inverting: system, RTC and
# wall clock all read 22:18:03.
#
# IMPORTANT — this must stay safe on the OTHER models in this family. The Plus has an RTC; the
# original Miyoo Mini is widely reported not to (and any unit's backup cell can die). Trusting the
# RTC unconditionally would leave such a device sitting at the kernel's 1970 epoch with the
# file-restore fallback disabled — a worse clock than before.
#
# So this does NOT assume an RTC exists: it asks whether the clock the kernel came up with is
# PLAUSIBLE. The kernel seeds the system clock from the RTC at boot when one is present, so a
# sane year means a working RTC, and 1970 means there isn't one (or it lost power).
#   RTC present + sane  -> keep it (correct time, no rewind)
#   no RTC / dead cell  -> fall back to datetime.txt exactly as upstream does
# `disable-rtc` forces the file-restore path regardless.
RTC_SANE=0
[ "$(date +%Y)" -ge 2024 ] 2>/dev/null && RTC_SANE=1
if [ -f "$DATETIME_PATH" ] && { [ "$RTC_SANE" = "0" ] || [ -f "$USERDATA_PATH/disable-rtc" ]; }; then
	DATETIME=`cat "$DATETIME_PATH"`
	date +'%F %T' -s "$DATETIME"
	DATETIME=`date +'%s'`
	date -u -s "@$DATETIME"
fi

#######################################

AUTO_PATH=$USERDATA_PATH/auto.sh
if [ -f "$AUTO_PATH" ]; then
	"$AUTO_PATH"
fi

cd $(dirname "$0")

#######################################

EXEC_PATH=/tmp/minui_exec
NEXT_PATH="/tmp/next"
touch "$EXEC_PATH"  && sync
while [ -f "$EXEC_PATH" ]; do
	minui.elf &> $LOGS_PATH/minui.txt
	
	echo `date +'%F %T'` > "$DATETIME_PATH"
	sync
	
	if [ -f $NEXT_PATH ]; then
		CMD=`cat $NEXT_PATH`
		# Re-decide ownership at EVERY launch. The daemon can die between games, and a verdict
		# computed at boot would keep routing games to an OSS endpoint that no longer exists — the
		# game would run silently while looking perfectly healthy.
		#
		# Revival is attempted AT MOST ONCE per session, and usually cannot work. MEASURED: once
		# minui.elf has the codec open, a restarted daemon dies immediately with
		#     MI_AO_SetPubAttr[3364]: Dev0 failed to set pub attr!!! error number:0xa0052009
		# the same "cannot reconfigure an ENABLED device" wall this project keeps hitting. The
		# daemon only wins the codec at boot, before the menu opens it. So retrying on every launch
		# would stall each one for the full readiness timeout and still fail; after one failure we
		# stay on direct MMIYOO for the rest of the session and recover at the next boot.
		if audio_daemon_ok || { [ "$AUDIO_RETRY" = "1" ] && audio_daemon_start; }; then
			AUDIO_DAEMON=1
			export SDL_AUDIODRIVER=dsp
			# NOT exported. Exporting put the shim on every helper the pak spawns -- needs-swap,
			# dd, mkswap, say.elf -- and this file states two screens up that libpadsp segfaults
			# non-SDL clients that drive /dev/dsp. Applied to the minarch process ALONE, at its
			# exec, via MINARCH_PRELOAD (see the pak launch.sh invocation).
			MINARCH_PRELOAD=$AUDIO_SHIM
		else
			# EXPLICIT fallback, and it must name the driver. Merely unsetting SDL_AUDIODRIVER is
			# not enough: OSS is registered BEFORE MMIYOO in SDL2 bootstrap[] (src/audio/SDL_audio.c
			# -- DSP at 114, MMIYOO at 126), so SDL would auto-pick dsp again and route into
			# nothing. The pop returns on this path; silence would be the worse failure.
			# Take the codec back first. Reaching here with a daemon still running means it is
			# wedged or unreachable; it would keep MI_AO and this game would open nothing.
			audio_daemon_release
			AUDIO_DAEMON=0
			AUDIO_RETRY=0   # do not stall every later launch on a revival that cannot succeed
			export SDL_AUDIODRIVER=MMIYOO
			MINARCH_PRELOAD=
		fi
		# The game needs its OWN ownership mode: in daemon mode minarch is only an OSS client and
		# must NOT disable the codec on exit/crash (PLAT_resetAudio honours this).
		export AUDIO_DAEMON MINARCH_PRELOAD
		eval $CMD
		unset SDL_AUDIODRIVER MINARCH_PRELOAD
		rm -f $NEXT_PATH
		if [ -f "/tmp/using-swap" ]; then
			swapoff $USERDATA_PATH/swapfile
			rm -f "/tmp/using-swap"
		fi
		
		echo `date +'%F %T'` > "$DATETIME_PATH"
		sync
	fi
done

shutdown # just in case
