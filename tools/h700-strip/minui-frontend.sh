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
# (panelprobe 2026-08-04). The others are computed from the timings in the device tree each image boots
# (pixel clock / (htotal * vtotal)), not muOS's screen/refresh, which read 60.011 for the same Plus panel
# (audit 2026-09-25). The board name comes from .system/h700/board, written by the image build.
case "$(cat /mnt/mmc/.system/h700/board 2>/dev/null)" in
	pro)              export MINARCH_PANEL_FPS=59.935 ;;
	sp)               export MINARCH_PANEL_FPS=60.004 ;;
	rg40xx-h|rg40xx-v) export MINARCH_PANEL_FPS=59.981 ;;
	*)                export MINARCH_PANEL_FPS=59.9777 ;;   # plus, h (same timings), and anything unknown
esac
# ALSA-direct: pipewire is stripped from the image, and asound.conf routes "default" straight to the
# codec (plug -> hw:0,0). SDL must not go looking for a sound server that is not there.
export SDL_AUDIODRIVER=alsa

LOG=/mnt/mmc/minui-zero.log
: > "$LOG" 2>/dev/null
echo "MinUI Zero frontend $(date 2>/dev/null)" >> "$LOG"

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
echo "governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)" >> "$LOG"

# WiFi + SSH bring-up. Credentials are USER-SUPPLIED (never baked into the image): the MinUI
# convention is a wifi.txt at the SD-card root, "SSID:password" per line, '#' comments. We use the
# first network. No wifi.txt = offline (MinUI is offline-by-default anyway) and this whole block
# stays quiet, so the efficient default is untouched.
#
# WiFi is delegated ENTIRELY to muOS's own net.sh connect — the exact flow that already connects
# reliably on this chip. Hand-rolling it (our own wpa/dhcp/keepalive) is what broke it repeatedly, so
# we stop and reference the fork: repopulate muOS's config from the user's wifi.txt and call
# `network.sh connect`, which runs the whole proven bring-up — loads 8821cs off the SDIO controller
# (device network.sh LOAD_NETWORK; a boot never loads it on its own), scans, builds the wpa config with
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
				echo "wifi monitor: offline, re-running connect" >> "$LOG"
				/opt/muos/script/system/network.sh connect >> "$LOG" 2>&1
				_down=0
			fi
		  done ) &
	fi
  fi
  # SSH via dropbear (we ship dropbearmulti, ~250KB; muOS's 32MB openssh is stripped). Key-auth
  # only, reading /root/.ssh/authorized_keys; the ed25519 host key lives on the card so the
  # fingerprint stays stable across boots. Same pattern the Smart Pro uses (skeleton .../dev-net.sh).
  # A release image ships NO key (the build only bakes one in dev mode), so ssh is opt-in the same
  # way wifi is: drop your public key at the card root as authorized_keys and it is installed here.
  # The card is the only writable surface a user has, the rootfs is not reachable without ssh, so
  # requiring them to edit /root/.ssh first would be a chicken-and-egg.
  mkdir -p /root/.ssh 2>/dev/null
  if [ -s "$SDCARD_PATH/authorized_keys" ]; then
    cp "$SDCARD_PATH/authorized_keys" /root/.ssh/authorized_keys 2>/dev/null
  fi
  chmod 700 /root/.ssh 2>/dev/null; chmod 600 /root/.ssh/authorized_keys 2>/dev/null
  DBM="$SYSTEM_PATH/bin/dropbearmulti"
  DBKEY="$USERDATA_PATH/dropbear_ed25519_host_key"
  # No key = nobody can authenticate (dropbear runs key-auth only), so the daemon would be a listening
  # port and idle weight that can never serve anyone. Start it only when a key is actually present.
  if [ -x "$DBM" ] && [ -s /root/.ssh/authorized_keys ] && ! pgrep dropbearmulti >/dev/null 2>&1; then
    mkdir -p "$USERDATA_PATH" 2>/dev/null
    [ -f "$DBKEY" ] || "$DBM" dropbearkey -t ed25519 -f "$DBKEY" 2>/dev/null
    "$DBM" dropbear -r "$DBKEY" -p 22 2>/dev/null
  fi
  # DEVMODE-ONLY ssh hardening (2026-08-10, after a night of dropped sessions). Two failure modes:
  #   1. The RTL8821CS dozes between muOS keepalive.sh's 60s pings, so the first packets of any new
  #      connection die (ssh "no answer" until a ping warms the radio). A 10s gateway ping keeps the
  #      radio hot continuously.
  #   2. dropbear wedges when rapid aborted connection attempts exhaust its half-open slots — port
  #      accepts but no session ever starts, and only a restart clears it. A 30s banner probe
  #      (an ssh server must greet with "SSH-") restarts dropbear after 2 consecutive silent probes.
  # Gated on devmode.txt: this is dev-loop plumbing and idle-power weight; never in a release.
  if [ -f "$SDCARD_PATH/devmode.txt" ] && [ -x "$DBM" ]; then
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
          "$DBM" dropbear -r "$DBKEY" -p 22 2>/dev/null
          _pf=0
        fi
      done ) &
  fi
  echo "wifi: $(ip -4 -o addr show wlan0 2>/dev/null | awk '{print $4}') ssh=$(pgrep dropbearmulti >/dev/null && echo up || echo down)" >> "$LOG"
) &

# The ROMS expander runs before the card is mounted, so its log lands on the rootfs where a
# user cannot reach it. Copy it onto the card now that the card is mounted.
[ -f /var/minui-zero-expand.log ] && cat /var/minui-zero-expand.log >> "$LOG" 2>/dev/null

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

# power-off the muOS way (AXP register; plain poweroff reboots) — reused from halt.sh
power_off() {
	sync
	echo 0x1801 > /sys/class/axp/axp_reg 2>/dev/null
	/opt/muos/script/system/halt.sh poweroff 2>/dev/null
	poweroff -f
}

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

cd /tmp
FAILS=0
while : ; do
	rm -f /tmp/next /tmp/poweroff
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
