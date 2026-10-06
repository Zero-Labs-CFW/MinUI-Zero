#!/bin/sh
# MinUI Zero — the "frontend" of the stripped-muOS OS. muOS's startup.sh brings up ALL the hard
# parts (kernel modules via udev, wifi via network.sh, ssh, mounts, power) exactly as it always
# has; startup.sh's `FRONTEND start` line is swapped for this, so MinUI is the UI instead of
# muxfrontend. Everything below the UI is muOS's proven stack — we reinvent nothing.
#
# muOS mounts the ROMS/data partition at /mnt/mmc (via /opt/muos/script/mount). Our payload lives
# there under .system/h700, same as the piggyback/hosted-dev loop.

export PLATFORM=h700
export SDCARD_PATH=/mnt/mmc
export SYSTEM_PATH=/mnt/mmc/.system/h700
export USERDATA_PATH=/mnt/mmc/.userdata/h700
export LOGS_PATH=/mnt/mmc/.userdata/h700/logs
export SHARED_USERDATA_PATH=/mnt/mmc/.userdata/shared
export SAVES_PATH=/mnt/mmc/Saves
export BIOS_PATH=/mnt/mmc/Bios
export CORES_PATH=/mnt/mmc/.system/h700/cores
# Same names and places as MinUI.pak/launch.sh and tg5040: ROMS_PATH for paks, DATETIME_PATH for the
# clock save/restore below (ported from launch.sh, which images never run, 2026-09-27).
export ROMS_PATH=/mnt/mmc/Roms
export DATETIME_PATH=/mnt/mmc/.userdata/shared/datetime.txt
# devmode flag: "devmode" or "devmode.txt" at the card root, like every other card-root flag (flagExists
# in C does the same). Dev mode = stay-awake + the ssh keepers below.
devmode() { [ -f "$SDCARD_PATH/devmode" ] || [ -f "$SDCARD_PATH/devmode.txt" ]; }
# Pak-contract env the wider scene expects (NextUI PAKS.md; MinUI heritage). CHEATS_PATH is part of
# every pak's boilerplate and DEVICE is minarch's sub-device discriminator (config.device_tag) —
# neither was exported here, so third-party paks that use them got empty paths. Community paks are
# the opt-in feature rail (Dan 2026-08-10), so the contract has to be complete.
export CHEATS_PATH=/mnt/mmc/Cheats
# plus vs h (near-twins; muOS resolves the board for us). Consumed by paks and minarch alike.
export DEVICE=$(sed 's/^rg35xx-//' /opt/muos/device/config/board/name 2>/dev/null || echo plus)
export LD_LIBRARY_PATH=/mnt/mmc/.system/h700/lib:/usr/lib:/lib
# Shipped helper binaries (confirm.elf, say.elf, minarch.elf, ...) on PATH, matching tg5040, tool
# and emulator paks call them bare, so without this every community pak written against the normal
# MinUI contract fails with "not found". Ours worked only because they used absolute paths.
export PATH=/mnt/mmc/.system/h700/bin:$PATH
# audio: pipewire is REMOVED (build-h700-stripped.sh). startup.sh's trimmed pipewire.sh does the
# codec init (alsactl restore) at boot; ALSA routes default->hw directly (asound.conf); minui and
# the emu paks use SDL_AUDIODRIVER=alsa. Nothing audio-related to do here.
export SDL_VIDEODRIVER=dummy
# DEVICE properties, not per-system ones, so they belong to the entry point rather than to each of
# the 15 emu paks that used to repeat them verbatim (2026-08-26).
# Panel refresh per board; minarch paces against the real rate, not 60. The Plus was MEASURED at 59.9777 Hz
# (panelprobe 2026-08-04). The SP and 40XX are computed from the timings in the device tree each image boots
# (pixel clock / (htotal * vtotal)), not muOS's screen/refresh, which read 60.011 for the same Plus panel
# (audit 2026-09-25). The Pro's old 59.935 came from the tree it shipped with before; the image now boots
# the muOS 3f2fa25 Pro package, whose panel timings equal the Plus/H (lcd_dclk_freq 0x30, lcd_ht 0x586,
# lcd_vt 0x236), so it takes the measured Plus/H value (2026-09-27). The board name comes from
# .system/h700/board, written by the image build.
case "$(cat /mnt/mmc/.system/h700/board 2>/dev/null)" in
	sp)               export MINARCH_PANEL_FPS=60.004 ;;
	rg40xx-h|rg40xx-v) export MINARCH_PANEL_FPS=59.981 ;;
	*)                export MINARCH_PANEL_FPS=59.9777 ;;   # plus, h, pro (same timings), and anything unknown
esac
# ALSA-direct: pipewire is stripped from the image, and asound.conf routes "default" straight to the
# codec (plug -> hw:0,0). SDL must not go looking for a sound server that is not there.
export SDL_AUDIODRIVER=alsa
# Audio ring occupancy servo (rate control on ring fill, as RetroArch/NextUI do). Required since the ring
# was resized and the loop became video-clocked (2026-10-03): without it a few ppm of match error
# walks the ring to empty (underruns) or full (lag). This script, not paks/MinUI.pak, is what the image
# runs, so the export must live here. =0 kills it for an A/B.
export ZERO_AUDIO_SERVO=1

# Always on, one boot's worth (truncated here), hidden in the logs folder like tg5040's and the Miyoo's
# minui.txt. It sat at the card root until 2026-09-28, where every user saw it next to Roms.
LOG="$LOGS_PATH/minui-zero.log"
mkdir -p "$LOGS_PATH" 2>/dev/null
: > "$LOG" 2>/dev/null
rm -f "$SDCARD_PATH/minui-zero.log" 2>/dev/null # the old card-root copy on cards upgraded from before the move (code review, 2026-10-05)
# Hard cap: past 256KB keep the newest 1000 lines, so no source (a WiFi reconnect loop out of range all day,
# a chatty menu session that never reboots) can grow it. Rewritten IN PLACE (cat >, not mv) so a writer
# holding the log open, minui.elf or a background connect, keeps appending to the same file. Called before
# each menu start and each WiFi retry, the two places it can grow.
trim_log() {
	[ "$(wc -c 2>/dev/null < "$LOG" || echo 0)" -gt 262144 ] || return 0
	# The menu loop and the WiFi monitor both call this: one at a time (mkdir is atomic; the other skips, the
	# next call trims), or two trims interleaved on one temp file and emptied the log (code review, 2026-10-05).
	# The lock is in /tmp so a power cut mid-trim cannot leave it behind on the card.
	if ! mkdir /tmp/minui-zero-log.trim 2>/dev/null; then
		# A trim takes milliseconds, so a lock older than a minute was left by a caller killed mid-trim and would
		# stop every trim until reboot (Codex review 4, 2026-10-06): reclaim it. The lock carries its own creation
		# time (busybox here may have no stat), and both numbers are checked before any arithmetic: a malformed
		# $(( )) is fatal to this non-interactive shell. A lock without a readable time is treated as live.
		_tl_m=$(cat /tmp/minui-zero-log.trim/at 2>/dev/null); _tl_n=$(date +%s 2>/dev/null)
		case "$_tl_m" in ''|*[!0-9]*) return 0 ;; esac
		case "$_tl_n" in ''|*[!0-9]*) return 0 ;; esac
		[ $((_tl_n - _tl_m)) -gt 60 ] || return 0
		rm -rf /tmp/minui-zero-log.trim
		mkdir /tmp/minui-zero-log.trim 2>/dev/null || return 0
	fi
	date +%s > /tmp/minui-zero-log.trim/at 2>/dev/null
	tail -n 1000 "$LOG" > "$LOG.tmp" 2>/dev/null && cat "$LOG.tmp" > "$LOG" && echo "(log trimmed to its newest 1000 lines)" >> "$LOG"
	rm -f "$LOG.tmp"
	rm -rf /tmp/minui-zero-log.trim
}
echo "MinUI Zero frontend $(date 2>/dev/null)" >> "$LOG"

# BOARD PINS the Plus kernel does not own (the SP and 40XX images run the RG35XX Plus kernel). Each line
# reproduces what that board's OWN muOS kernel does at probe (disassembled, research 2026-09-25):
#  RG40XX H/V: LED MCU power PE5 (gpio 133) + PI7 (263) driven LOW, so the RGB LEDs are dark, never lit and
#   draining with no way to turn them off. 40XX only: on the RG35XX H the same two pins are USB power
#   (allen_usb2_pwr_en / allen_usb2_vbus_en in its tree).
#  RG35XX SP: WiFi enable PG18 (gpio 210) driven HIGH, as the Plus driver does at power-on; muOS's SP tree
#   dropped the wlan_regon entry, so nothing else releases the chip from reset.
# HOW. sysfs first, but these kernels are built without GPIO_SYSFS, so /sys/class/gpio does not exist and
# that write was a silent no-op on every image (cross-reference 2026-09-27). Fallback: the PIO registers
# through busybox devmem (/sbin/devmem in our rootfs; the kernel has DEVMEM=y, STRICT_DEVMEM off). A
# register write is hardware state, so it outlives this script, where a gpiochip line handle is freed when
# its fd closes. Layout: pio base 0x0300b000 (reg of /soc@03000000/pinctrl@0300b000 in all six board
# trees), bank n at base + n*0x24, CFG register (pin/8)*4 holding a 4-bit field per pin (1 = output), DAT
# at bank + 0x10 with one bit per pin (Linux pinctrl-sunxi.h BANK_MEM_SIZE 0x24 / DATA_REGS_OFFSET 0x10,
# the layout its H616 driver uses). Only that field and that bit change, DAT before CFG so the pin comes up
# at its level. FAIL SAFE: a sysfs that refuses the pin, no pio node at that base, no devmem, a pin a
# peripheral owns (field not 0 input, 1 output or 7 off) or a readback mismatch leaves the pin as it was,
# and the log line says which path ran. Known limit: each read and write is its own devmem run, not atomic
# with the kernel's pinctrl lock, so a kernel change to ANOTHER pin of the same bank in the milliseconds
# between them would be undone (boot only, once per pin; no userspace fix).
# Not device-tested (no SP or 40XX on hand); whether the value survives deep sleep is also unverified.
PIO_BASE=0x0300b000
PIO_DT=/proc/device-tree/soc@03000000/pinctrl@0300b000
_devmem() { if command -v devmem >/dev/null 2>&1; then devmem "$@"; else busybox devmem "$@"; fi; }
_pin() { # <gpio> <low|high>
	if [ -e /sys/class/gpio/export ]; then
		[ -e /sys/class/gpio/gpio$1 ] || echo $1 2>/dev/null > /sys/class/gpio/export   # 2> first: a failed > still prints
		echo $2 2>/dev/null > /sys/class/gpio/gpio$1/direction && { echo "pin $1 $2: sysfs" >> "$LOG"; return 0; }
		# a kernel WITH gpio sysfs that refuses the pin has a driver owning it: never override that via devmem
		echo "pin $1 $2: NOT driven (sysfs refused it)" >> "$LOG"; return 1
	fi
	grep -q sun50iw9p1-pinctrl "$PIO_DT/compatible" 2>/dev/null || { echo "pin $1 $2: NOT driven (no pio at $PIO_BASE)" >> "$LOG"; return 1; }
	_pb=$(( PIO_BASE + ($1 / 32) * 0x24 )); _pn=$(( $1 % 32 )); _pw=0; [ "$2" = high ] && _pw=1
	_pcfg=$(( _pb + (_pn / 8) * 4 )); _psh=$(( (_pn % 8) * 4 )); _pdat=$(( _pb + 0x10 ))
	# every devmem answer is format-checked BEFORE any arithmetic: a bad value in $(( )) aborts this shell
	_pc=$(_devmem $_pcfg 32 2>/dev/null); _pd=$(_devmem $_pdat 32 2>/dev/null)
	case "$_pc:$_pd" in 0x*:0x*) ;; *) echo "pin $1 $2: NOT driven (devmem unavailable)" >> "$LOG"; return 1 ;; esac
	case $(( ($_pc >> _psh) & 15 )) in 0|1|7) ;; *) echo "pin $1 $2: NOT driven (owned by a peripheral, cfg $_pc)" >> "$LOG"; return 1 ;; esac
	_devmem $_pdat 32 $(( ($_pd & ~(1 << _pn)) | (_pw << _pn) )) 2>/dev/null && \
		_devmem $_pcfg 32 $(( ($_pc & ~(15 << _psh)) | (1 << _psh) )) 2>/dev/null
	_pc=$(_devmem $_pcfg 32 2>/dev/null); _pd=$(_devmem $_pdat 32 2>/dev/null)
	case "$_pc:$_pd" in 0x*:0x*) ;; *) _pc=0x0; _pd=0x0 ;; esac
	if [ $(( ($_pc >> _psh) & 15 )) = 1 ] && [ $(( ($_pd >> _pn) & 1 )) = $_pw ]; then
		echo "pin $1 $2: devmem (cfg $(printf 0x%08x $_pcfg) = $_pc, dat $(printf 0x%08x $_pdat) = $_pd)" >> "$LOG"
	else
		echo "pin $1 $2: devmem write NOT confirmed (cfg $_pc, dat $_pd)" >> "$LOG"; return 1
	fi
}
case "$DEVICE" in
	rg40xx-h|rg40xx-v) _pin 133 low; _pin 263 low ;;
	sp)                _pin 210 high ;;
esac

# CLOCK. When the clock comes up before 2025 (no RTC time survived the power-off), restore the last time
# the launch loop saved below, so saves and logs do not stamp 1970. A clock that held is left alone.
if [ "$(date +%Y)" -lt 2025 ] && [ -f "$DATETIME_PATH" ]; then
	date -s "$(cat "$DATETIME_PATH")" >/dev/null 2>&1 && echo "clock: restored $(date 2>/dev/null)" >> "$LOG"
fi

# CARD HYGIENE. macs and windows leave droppings on any card they mount (._* resource forks, .DS_Store,
# Thumbs.db, desktop.ini). MinUI hides them, Device Sync ignores them, and this sweeps them each boot so they
# do not accumulate; known junk names only, never a user file (parity with the Brick launcher, 2026-09-22).
# The deep sweep waits 15 s and until no game runs, niced, so it never competes with the menu or a launch.
rm -f "$SDCARD_PATH/.DS_Store" "$SDCARD_PATH"/._* 2>/dev/null
( sleep 15; while pidof minarch.elf >/dev/null 2>&1; do sleep 30; done; nice -n 19 find "$ROMS_PATH" "$BIOS_PATH" "$SAVES_PATH" "$SDCARD_PATH/Collections" \( -name "._*" -o -name ".DS_Store" -o -name "Thumbs.db" -o -name "ehthumbs.db" -o -name "desktop.ini" \) -exec rm -f {} + 2>/dev/null ) &

# NOTE: an "efficiency" kill of muOS idle daemons (lowpower/keepalive/muhotkey/activity) lived here
# but was removed (2026-08-06). It was an UNMEASURED optimization — the thesis is "earn it by
# measurement," and this was vibes ("loops burn wakeups") without a wakeup receipt or a per-service
# safety check. keepalive.sh in particular is a plausible network keepalive, and a device that boots
# then drops wifi (seen live) is a far worse outcome than a few shell-loop wakeups. Revisit only with
# a measured per-service wakeup cost + a proven-safe-to-kill check, one service at a time.

# CODEC INIT (audio): restore the mixer state (unmute + digital volume 24) SYNCHRONOUSLY before
# minui starts. startup.sh's line-63 `pipewire.sh start &` also does this, but BACKGROUNDED, so it
# races minui's InitSettings (which reads the codec volume ONCE at launch). Losing that race left
# digital volume at the power-on 0 = dead silent (found live 2026-08-06). Doing it here, blocking,
# guarantees the codec is unmuted and at its 24 baseline before minui ever reads it.
alsactl -U -f /opt/muos/device/control/asound.state restore 2>/dev/null

# Re-assert the USER's volume over that baseline, and again at every process boundary below.
# Why this exists: the only muter is PWR_enterSleep (api.c SetRawVolume(MUTE_VOLUME_RAW) -> raw 0),
# and the matching un-mute lives in PWR_exitSleep *inside the same process*. If that process is
# replaced while muted — faux-sleep then a relaunch, a crash, or a dev deploy that restarts minui —
# nobody ever writes the level back and the codec stays at 0 through the next game launch, which is
# the "audio way lowered when starting a new game" report (captured live 2026-08-10: screen on,
# game running, raw=0, saved level still 16). libmsettings persists the UI level to $VOL_FILE;
# applying it here makes the codec match the saved level at every boundary, whoever muted it.
VOL_FILE="$USERDATA_PATH/volume"   # UI 0-20, written by libmsettings SetVolume
apply_volume() {
	[ -f "$VOL_FILE" ] || return 0
	_ui=$(cat "$VOL_FILE" 2>/dev/null)
	case "$_ui" in ''|*[!0-9]*) return 0 ;; esac   # ignore a garbage/partial file
	[ "$_ui" -gt 20 ] && _ui=20
	amixer -c 0 sset 'digital volume' $(( _ui * 63 / 20 )) >/dev/null 2>&1   # UI 0-20 -> raw 0-63
}
apply_volume
echo "audio: digital volume $(amixer -c 0 sget 'digital volume' 2>/dev/null | grep -oE '[0-9]+ \[' | tr -d ' [')" >> "$LOG"

# THE THESIS: own the governor. schedutil + our minui/minarch write the ceiling on top.
echo schedutil > /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null
# 1512 MHz ceiling for the menu and tools (startup.sh already set it at boot; minarch writes lower ceilings
# per game on top). The SP/Pro/40XX trees list 1608/1704 MHz, past verified stock (audit 2026-09-25).
echo 1512000 > /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq 2>/dev/null
echo "governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)" >> "$LOG"
echo "cpu ceiling: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq 2>/dev/null) of $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_frequencies 2>/dev/null)" >> "$LOG"
# GPU ceiling 648 MHz, the Plus tree's top: the H/Pro/SP/40XX trees add 756 MHz at 1.000 V (see the module.sh
# edit in build-h700-stripped.sh, which sets it as mali_kbase loads). Re-asserted and logged here, like the CPU.
for _g in /sys/class/devfreq/*gpu*; do
	[ -w "$_g/max_freq" ] && echo 648000000 > "$_g/max_freq" 2>/dev/null
	echo "gpu ceiling: $_g $(cat "$_g/max_freq" 2>/dev/null) of $(cat "$_g/available_frequencies" 2>/dev/null)" >> "$LOG"
done

# Bluetooth radio off, by rfkill type (same as TrimUI boot.sh). The image already strips the Bluetooth
# stack (libbluetooth), but nothing blocked the radio itself; Bluetooth is never supported (Dan, 2026-10-05).
for _r in /sys/class/rfkill/rfkill*; do
	[ "$(cat "$_r/type" 2>/dev/null)" = "bluetooth" ] && echo 0 > "$_r/state" 2>/dev/null
done
echo "rfkill: $(for _r in /sys/class/rfkill/rfkill*; do printf '%s=%s ' "$(cat "$_r/type" 2>/dev/null)" "$(cat "$_r/state" 2>/dev/null)"; done)" >> "$LOG"

# WiFi + SSH bring-up. Credentials are USER-SUPPLIED (never baked into the image): the MinUI
# convention is a wifi.txt at the SD-card root, "SSID:password" per line, '#' comments. We use the
# first network. No wifi.txt = offline (MinUI is offline-by-default anyway) and this whole block
# stays quiet, so the efficient default is untouched.
#
# WiFi is delegated ENTIRELY to muOS's own net.sh connect — the exact flow that already connects
# reliably on this chip. Hand-rolling it (our own wpa/dhcp/keepalive) is what broke it repeatedly, so
# we stop and reference the fork: repopulate muOS's config from the user's wifi.txt and call
# `network.sh connect`, which runs the whole proven bring-up — loads 8821cs off the SDIO controller
# (device network.sh LOAD_NETWORK, whenever mmc2:0001 is absent; a boot never loads it on its own since
# the image build dropped the modprobe from muOS module.sh load, 2026-09-27), scans, builds the wpa config with
# wpa_passphrase (password.sh), DHCPs, validates, then starts keepalive.sh: muOS's own rtw_power_mgnt=0
# idle-drop fix (credit johnnyonflame) plus a reconnect monitor. Verified the image's device config has
# what the flow reads: board/name=rg35xx-plus (driver-load path), network/type=nl80211 (wpa starts),
# network/iface=wlan0. Ref: net.sh / password.sh / keepalive.sh under /opt/muos/script.
# SSH: dropbear (we ship dropbearmulti; muOS's openssh is stripped), started once below.
WIFI_TXT=/mnt/mmc/wifi.txt

( if [ -f "$WIFI_TXT" ]; then
	# wifi.txt: "SSID:password" per line, '#' comments; first network wins. Creds are written to muOS's
	# config at RUNTIME (never baked into the image — the build wipes them) and consumed by net.sh
	# connect below. SSID must be BROADCAST: muOS's scan-based SSID_PRESENT + password.sh (normal-length
	# passphrase) don't set scan_ssid, so a hidden SSID fails here exactly as it would on stock muOS.
	_line=$(sed '/^#/d;/^[[:space:]]*$/d' "$WIFI_TXT" | head -1)
	_ssid=${_line%%:*}; _psk=${_line#*:}
	if [ -n "$_ssid" ] && [ "$_ssid" != "$_line" ] && [ -f /opt/muos/script/var/func.sh ]; then
		# sub-subshell so whatever func.sh defines/sets stays contained (never touches the SSH block)
		( . /opt/muos/script/var/func.sh
		  SET_VAR "config" "network/ssid"   "$_ssid"
		  SET_VAR "config" "network/pass"   "$_psk"
		  SET_VAR "config" "network/hidden" "0"
		  SET_VAR "config" "network/type"   "0"
		  SET_VAR "config" "settings/network/con_retry"  "3"
		  SET_VAR "config" "settings/network/compat"     "1"
		  SET_VAR "config" "settings/network/wait_timer" "10"
		  SET_VAR "config" "settings/network/monitor"    "1" )
		# muOS's own proven bring-up: driver load + scan + wpa_passphrase + dhcp + validate + keepalive.
		/opt/muos/script/system/network.sh connect >> "$LOG" 2>&1 &
		# RECONNECT MONITOR: the boot-time connect is ONE-SHOT — net.sh exits for good after its 3
		# retries, so one bad roll (SDIO/scan race on early boot; the known line-67 IAID error) left
		# the device offline until the next reboot (seen live 2026-08-10). While wifi.txt is present,
		# re-run the whole proven connect whenever wlan0 has no IPv4 on two checks in a row (~90s
		# cadence; a connect takes ~30s, so checks never overlap a run in progress).
		( _down=0
		  while : ; do
			sleep 45
			[ -f "$WIFI_TXT" ] || continue
			if ip -4 -o addr show wlan0 2>/dev/null | grep -q inet; then _down=0; continue; fi
			_down=$((_down+1))
			if [ $_down -ge 2 ]; then
				trim_log
				echo "wifi monitor: offline, re-running connect" >> "$LOG"
				/opt/muos/script/system/network.sh connect >> "$LOG" 2>&1
				_down=0
			fi
		  done ) &
	fi
  fi
  # SSH via dropbear (we ship dropbearmulti, ~250KB; muOS's 32MB openssh is stripped). Key-auth
  # only, reading /root/.ssh/authorized_keys: every dropbear start below passes -s (no password
  # logins), and the image build locks root's password as well. Before 2026-09-27 this said key-only
  # while dropbear ran WITHOUT -s, so the donor rootfs password (root) logged in as soon as a user
  # dropped a key on the card (9c2cb2dd fixed only MinUI.pak/launch.sh, which images never run).
  # The ed25519 host key lives on the card so the fingerprint stays stable across boots. Same pattern
  # the Smart Pro uses (skeleton .../dev-net.sh).
  # A release image ships NO key (the build only bakes one in dev mode), so ssh is opt-in the same
  # way wifi is: drop your public key at the card root as authorized_keys and it is installed here.
  # The card is the only writable surface a user has, the rootfs is not reachable without ssh, so
  # requiring them to edit /root/.ssh first would be a chicken-and-egg.
  # The copy on the rootfs outlives the card file, so taking the key off the card takes it back out, or
  # ssh (and the stay-awake below) could never be switched off from the card. Only a key this block
  # installed goes (the .from-card marker): a dev image's baked-in key has no marker and is kept.
  mkdir -p /root/.ssh 2>/dev/null
  if [ -s "$SDCARD_PATH/authorized_keys" ]; then
    cp "$SDCARD_PATH/authorized_keys" /root/.ssh/authorized_keys 2>/dev/null && touch /root/.ssh/.from-card 2>/dev/null
  elif [ -f /root/.ssh/.from-card ]; then
    rm -f /root/.ssh/authorized_keys /root/.ssh/.from-card 2>/dev/null
    echo "ssh: authorized_keys is off the card, removed the copy installed from it" >> "$LOG"
  fi
  chmod 700 /root/.ssh 2>/dev/null; chmod 600 /root/.ssh/authorized_keys 2>/dev/null
  DBM="$SYSTEM_PATH/bin/dropbearmulti"
  DBKEY="$USERDATA_PATH/dropbear_ed25519_host_key"
  # No key = nobody can authenticate (dropbear runs key-auth only), so the daemon would be a listening
  # port and idle weight that can never serve anyone. Start it only when a key is actually present.
  if [ -x "$DBM" ] && [ -s /root/.ssh/authorized_keys ] && ! pgrep dropbearmulti >/dev/null 2>&1; then
    mkdir -p "$USERDATA_PATH" 2>/dev/null
    [ -f "$DBKEY" ] || "$DBM" dropbearkey -t ed25519 -f "$DBKEY" 2>/dev/null
    "$DBM" dropbear -s -r "$DBKEY" -p 22 2>/dev/null   # -s: key-only, never a password
    # STAY AWAKE while SSH is up (Dan 2026-09-08, ported from MinUI.pak/launch.sh 2026-09-27). Idle
    # escalation would faux-sleep and then deep-sleep the device, and deep sleep tears wifi down, which
    # killed every remote session. STAY_AWAKE_PATH is honored by PWR_preventAutosleep (shared api.c).
    # Only reached when a key is present, i.e. the user opted into SSH; a release image ships no key.
    # And only with wifi.txt: this image has no USB networking (muOS usb_function=0), so without WiFi
    # nobody can reach SSH and staying awake would be pure drain. Dev cards need neither: devmode arms
    # the same flag in C (api.c PWR_init).
    [ -f "$WIFI_TXT" ] && touch /tmp/stay_awake 2>/dev/null
  fi
  # DEVMODE-ONLY ssh hardening (2026-08-10, after a night of dropped sessions). Two failure modes:
  #   1. The RTL8821CS dozes between muOS keepalive.sh's 60s pings, so the first packets of any new
  #      connection die (ssh "no answer" until a ping warms the radio). A 10s gateway ping keeps the
  #      radio hot continuously.
  #   2. dropbear wedges when rapid aborted connection attempts exhaust its half-open slots — port
  #      accepts but no session ever starts, and only a restart clears it. A 30s banner probe
  #      (an ssh server must greet with "SSH-") restarts dropbear after 2 consecutive silent probes.
  # Gated on devmode(.txt): this is dev-loop plumbing and idle-power weight; never in a release.
  if devmode && [ -x "$DBM" ]; then
    ( while : ; do
        _gw=$(ip route 2>/dev/null | awk '/default/{print $3; exit}')
        ping -c1 -W2 "${_gw:-192.168.1.1}" >/dev/null 2>&1
        sleep 10
      done ) &
    # watchdog needs busybox nc for the banner probe; without it, a probe that can never succeed
    # would restart dropbear every 60s forever — so only arm the watchdog when nc exists.
    busybox 2>/dev/null | grep -qw nc && \
    ( _pf=0
      while : ; do
        sleep 30
        _b=$(echo | busybox nc -w 3 127.0.0.1 22 2>/dev/null | head -c 4)
        if [ "$_b" = "SSH-" ]; then _pf=0; continue; fi
        _pf=$((_pf+1))
        if [ $_pf -ge 2 ]; then
          echo "devmode: dropbear unresponsive, restarting" >> "$LOG"
          killall dropbearmulti 2>/dev/null; sleep 1
          "$DBM" dropbear -s -r "$DBKEY" -p 22 2>/dev/null   # -s: key-only, same as the start above
          _pf=0
        fi
      done ) &
  fi
  echo "wifi: $(ip -4 -o addr show wlan0 2>/dev/null | awk '{print $4}') ssh=$(pgrep dropbearmulti >/dev/null && echo up || echo down) awake=$([ -f /tmp/stay_awake ] && echo y || echo n)" >> "$LOG"
) &

# The ROMS expander runs before the card is mounted, so its log lands on the rootfs where a
# user cannot reach it. Copy it onto the card now that the card is mounted. /var is persistent, so once
# the card has expanded, copy it ONE time and set it aside, or every later boot repeats the first
# boot's fdisk output. Until then (skipped, failed) it is copied every boot: that is the reason to read.
if [ -f /var/minui-zero-expand.log ]; then
	cat /var/minui-zero-expand.log >> "$LOG" 2>/dev/null
	[ -f /opt/minui-zero/roms-expanded ] && mv -f /var/minui-zero-expand.log /var/minui-zero-expand.log.shown 2>/dev/null
fi

# BOOT-TIME READAHEAD. The FIRST game launch after a boot is the slow one: everything it touches
# is cold on a ~10MB/s card. MEASURED 2026-08-10: the same game took 4348ms cold vs 707ms warm.
# Pull the fixed cost into the seconds after boot, while the user is still looking at the menu and
# the CPU is otherwise idle, so the first launch is as quick as the rest.
#
# libmali.so (42.5MB) WAS in this list and has been removed (2026-08-26). It was assumed to be the
# biggest single item because SDL dlopens it, "mali" being the only video driver this SDL2 has. It
# is not: we set SDL_VIDEODRIVER=dummy, that driver does not exist in this build, so SDL video init
# fails outright and we present through the DE hardware scaler instead. VERIFIED on-device against
# BOTH processes, menu and a running game: zero libmali/libEGL/libGLES mappings and no /dev/mali0
# fd in either. The readahead was reading 42.5MB off the card at every boot that nothing ever loads.
#
# This is page cache only: no process stays resident, the kernel evicts it under pressure, and it
# costs nothing the thesis measures (power, heat, resident memory). Reads are serialised and
# niced so they never compete with the menu for the card or the CPU.
( nice -n 19 sh -c '
	sleep 3                                   # let the menu draw first
	for f in 	         /usr/lib/libSDL2-2.0.so.0 /usr/lib/libSDL2_image-2.0.so.0 /usr/lib/libSDL2_ttf-2.0.so.0 \
	         "$SYSTEM_PATH/bin/minarch.elf" "$SYSTEM_PATH/lib/libmsettings.so"; do
		[ -f "$f" ] && cat "$f" > /dev/null 2>&1
	done
	# then the core for whatever was played last, which is the most likely next launch
	R="$SHARED_USERDATA_PATH/.minui/recent.txt"
	if [ -f "$R" ]; then
		T=$(sed -n "1p" "$R" | sed -n "s/.*(\([A-Z0-9]*\)).*/\1/p")
		[ -n "$T" ] && [ -f "$SYSTEM_PATH/paks/Emus/$T.pak/launch.sh" ] && \
			C=$(grep -o "[a-z0-9_-]*_libretro\.so" "$SYSTEM_PATH/paks/Emus/$T.pak/launch.sh" | head -1) && \
			[ -n "$C" ] && [ -f "$CORES_PATH/$C" ] && cat "$CORES_PATH/$C" > /dev/null 2>&1
	fi
' >/dev/null 2>&1 ) &

mkdir -p "$LOGS_PATH" "$SAVES_PATH" "$SHARED_USERDATA_PATH/.minui" 2>/dev/null

# COMMUNITY PAK COMPAT: the scene's canonical card mount is /mnt/SDCARD and paks hardcode it
# constantly (NextUI HOOKS.md documents that literal path), but muOS mounts ours at /mnt/mmc, so
# a hardcoded pak would write into a nonexistent tree and silently do nothing. A symlink costs one
# inode and makes both spellings the same place. Only when the real mount exists and the name is
# free — never clobber a real /mnt/SDCARD on a device that has one. See docs/pak-compatibility.md.
[ -d "$SDCARD_PATH" ] && [ ! -e /mnt/SDCARD ] && ln -s "$SDCARD_PATH" /mnt/SDCARD 2>/dev/null

# Save the wall clock for the CLOCK restore at the top (ported from MinUI.pak/launch.sh, which saves it
# after every game). Also saved at power-off here, the freshest point. Only a sane clock (2025 or later)
# is saved, so a boot that could not restore never overwrites the last good time with 1970.
save_clock() { [ "$(date +%Y)" -ge 2025 ] && date +'%F %T' > "$DATETIME_PATH" 2>/dev/null; }

# POWER OFF in muOS HEAD halt.sh order (H700 sweep 2026-09-28): nothing may still be writable when the power
# goes. The AXP write used to follow a bare sync with the card still mounted read-write, so every power-off left
# the FAT marked dirty. Now: save the clock, sync, then per writable block filesystem, cards first and root last,
# kill every process still using it except this shell (muOS keepalive.sh and its sleep child keep this log open
# for good, inherited from network.sh connect, and a remount refuses while any writer is left; never done for
# root) and remount it read-only. A mount that still refuses stays as it was, no worse than before; the 15 s
# backstop cuts power if a remount hangs on a failing card. Then the muOS way to cut power (AXP register; plain
# poweroff reboots), with halt.sh and poweroff -f as fallbacks. cd / first, so no cwd holds the card.
power_off() {
	save_clock
	sync
	cd /
	( sleep 15; echo 0x1801 > /sys/class/axp/axp_reg; poweroff -f ) >/dev/null 2>&1 &
	for _m in $(awk '$1 ~ /^\/dev\// && $3 ~ /^(ext2|ext3|ext4|vfat|msdos|exfat)$/ && $4 !~ /^ro(,|$)/ {
			if (!($1 in t) || length($2) < length(t[$1])) t[$1] = $2 }
		END { for (d in t) if (t[d] != "/") print t[d]; for (d in t) if (t[d] == "/") print t[d] }' /proc/mounts 2>/dev/null); do
		[ "$_m" = / ] || for _p in $(fuser -m "$_m" 2>/dev/null); do [ "$_p" = "$$" ] || kill -9 "$_p" 2>/dev/null; done
		for _t in 1 2 3; do mount -o remount,ro "$_m" 2>/dev/null && break; sleep 1; done   # a killed writer exits a moment later
	done
	sync
	echo 0x1801 > /sys/class/axp/axp_reg 2>/dev/null
	/opt/muos/script/system/halt.sh poweroff 2>/dev/null
	poweroff -f
}

# Boot receipt, DEV CARDS ONLY (devmode): kernel seconds when the first launch starts, one ~40-byte line
# per boot, the regression canary behind the README boot table (same line as MinUI.pak/launch.sh). Taken
# before boot-to-game so a resumed game's play time never lands in it. Costs users nothing.
devmode && echo "$(cut -d" " -f1 /proc/uptime) menu-ready $(date +%Y-%m-%d 2>/dev/null)" >> "$LOGS_PATH/boot-time.txt"

# BOOT STRAIGHT INTO THE GAME. MinUI already quicksaves on power-off and resumes on the next boot,
# but the resume goes through the launcher: it starts, reads the marker, writes /tmp/next and exits,
# so a resume pays a full launcher startup and a menu frame the user never wanted to see.
#
# Do it here instead. The contract is the launcher's own (minui.c autoResume): the marker holds a
# card-relative rom path, it is consumed exactly once (unlink before launching, so a crash cannot
# put us in a resume loop), and slot 9 in RESUME_SLOT_PATH tells minarch to load the auto-save.
# The pak is resolved the way the launcher resolves it: the (TAG) in the rom folder name.
#
# Every failure falls through to the normal launcher path, which is the safe default.
AUTO_RESUME="$SHARED_USERDATA_PATH/.minui/auto_resume.txt"
if [ -f "$AUTO_RESUME" ]; then
	_rel=$(head -1 "$AUTO_RESUME" 2>/dev/null)
	rm -f "$AUTO_RESUME"; sync            # consume it FIRST: never resume-loop on a bad entry
	_rom="$SDCARD_PATH$_rel"
	# tag = the (XXX) at the end of the rom's folder name, e.g. "Nintendo (FC)" -> FC
	_tag=$(dirname "$_rel" | sed -n 's/.*(\([A-Za-z0-9]*\))$/\1/p')
	_pak="$SYSTEM_PATH/paks/Emus/$_tag.pak/launch.sh"
	if [ -n "$_rel" ] && [ -f "$_rom" ] && [ -n "$_tag" ] && [ -f "$_pak" ]; then
		echo "boot-to-game: $_tag <- $_rel" >> "$LOG"
		echo 9 > /tmp/resume_slot.txt      # AUTO_RESUME_SLOT, read by minarch
		apply_volume
		sh "$_pak" "$_rom" >> "$LOG" 2>&1
		echo "boot-to-game exited rc=$?" >> "$LOG"
		[ -f /tmp/poweroff ] && { echo "poweroff requested (boot-to-game)" >> "$LOG"; power_off; }
	else
		echo "boot-to-game: skipped (rel=$_rel tag=$_tag)" >> "$LOG"
	fi
fi

# USER HOOK (MinUI contract, as MinUI.pak/launch.sh and tg5040): .userdata/h700/auto.sh runs once per
# boot, before the launcher.
AUTO_PATH="$USERDATA_PATH/auto.sh"
[ -f "$AUTO_PATH" ] && "$AUTO_PATH"

# Tools folded into Settings (Dan, 2026-09-16): Deep Sleep, Clock, Focus Mode and WiFi are rows of
# Settings.pak now. Drop the old paks from cards that had them (same list as MinUI.pak/launch.sh). Deep
# Sleep, Clock and Focus Mode are ours by name; the WiFi copy is marker-guarded because FAT32 folds case,
# so "WiFi.pak" is also the community Wifi.pak, which we must never delete.
for _p in "Deep Sleep.pak" "Clock.pak" "Focus Mode.pak" "WiFi Toggle.pak"; do
	rm -rf "$SDCARD_PATH/Tools/h700/$_p" 2>/dev/null
done
grep -q 'styled like Deep Sleep.pak' "$SDCARD_PATH/Tools/h700/WiFi.pak/launch.sh" 2>/dev/null && rm -rf "$SDCARD_PATH/Tools/h700/WiFi.pak" 2>/dev/null

cd /tmp
FAILS=0
while : ; do
	rm -f /tmp/next /tmp/poweroff
	trim_log
	"$SYSTEM_PATH/bin/minui.elf" >> "$LOG" 2>&1
	RC=$?
	# PLAT_powerOff (owned OS) drops /tmp/poweroff so the loop can tell a real poweroff request from
	# a normal game/menu exit — without it an in-game poweroff looked like a quit and re-launched the
	# same game (audit 2026-08-07).
	[ -f /tmp/poweroff ] && { echo "poweroff requested" >> "$LOG"; power_off; }
	if [ -f /tmp/next ]; then
		FAILS=0
		CMD=$(cat /tmp/next)
		echo "launch: $CMD" >> "$LOG"
		apply_volume   # a mute left behind by the menu process must not follow us into the game
		sh -c "$CMD"
		echo "game exited rc=$?" >> "$LOG"
		apply_volume   # ...nor back into the menu if the game was killed while muted
		save_clock; sync
		[ -f /tmp/poweroff ] && { echo "poweroff requested (in-game)" >> "$LOG"; power_off; }
	elif [ "$RC" = "0" ]; then
		echo "clean exit — power off" >> "$LOG"
		power_off
	else
		FAILS=$((FAILS+1))
		echo "minui exited rc=$RC (fail $FAILS)" >> "$LOG"
		# Retry so transient faults self-heal; persistent failure powers OFF rather than the old
		# infinite `sleep 60` park, which left a black, draining, unrecoverable device (audit).
		[ $FAILS -ge 5 ] && { echo "$FAILS consecutive fails — powering off" >> "$LOG"; power_off; }
		sleep 2
	fi
done
