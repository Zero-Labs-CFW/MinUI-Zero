#!/bin/sh
# Self-running device test suite for the TrimUI Brick Pro (tg5040, DEVICE=brickpro).
#
#   sh tools/brickpro-autotest.sh [user@host]
#
# Adapted from tools/mmp-autotest.sh. Drives the DEVICE over ssh: injects game launches through
# the /tmp/next + eval mechanism the menu itself uses (safe: MinUI.pak's loop guards on
# /tmp/minui_exec, so killing minui.elf just re-loops; shutdown only fires if that sentinel is
# removed), lets each game run unattended, then asserts.
#
# WHAT IT PROVES on its own, per system:
#   * minarch actually STARTS with that core and rom (a missing/ABI-broken core fails here)
#   * it SURVIVES the dwell without dying (bad core, bad cfg, OOM, scaler crash)
#   * the frontend picked BRICK PRO geometry (1024x768, DEVICE=brickpro) and not Smart Pro
#   * no core/frontend ERROR lines in that system's log
#   * a framebuffer grab is pulled as evidence
#
# WHAT STAYS MANUAL (physics): audio by ear, panel look, analog stick feel, rumble strength.
#
# Exit: games end with SIGTERM so minarch's Term_handler releases audio and restores volts.
set -u

TARGET=${1:-root@192.168.1.235}
KEY=/Users/dk/.ssh/tg5040_dev
SD=/mnt/SDCARD
SYS="$SD/.system/tg5040"
ROMS="$SD/Roms"
LOGS="$SD/.userdata/tg5040/logs"
ART=".notes/brickpro-autotest"
PASS=0; FAIL=0

mkdir -p "$ART"
rsh() { ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
	-o ConnectTimeout=8 -o BatchMode=yes -o LogLevel=ERROR "$TARGET" "$@"; }
note() { printf '%s\n' "$*"; }
pass() { PASS=$((PASS+1)); printf '  PASS  %s\n' "$*"; }
fail() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$*"; }

rsh 'echo ok' >/dev/null 2>&1 || { echo "device unreachable at $TARGET"; exit 1; }

# --- preflight: the whole point of this device's bring-up -------------------------------------
note "=== preflight"
MODEL=$(rsh 'cat /mnt/SDCARD/.userdata/tg5040/logs/model.txt 2>/dev/null' | tr '\n' ' ')
note "  $MODEL"
case "$MODEL" in
	*"device=brickpro"*) pass "model detection: DEVICE=brickpro" ;;
	*) fail "model detection: expected device=brickpro, got: $MODEL" ;;
esac
case "$MODEL" in
	*"1024x768"*) pass "panel: 1024x768" ;;
	*) fail "panel: expected 1024x768" ;;
esac
LEDS=$(rsh 'for f in /sys/class/led_anim/max_scale*; do printf "%s=%s " "$(basename $f)" "$(cat $f 2>/dev/null)"; done')
case "$LEDS" in
	*"max_scale_rear=0"*) pass "LEDs: shoulder zone dark ($LEDS)" ;;
	*) fail "LEDs: rear zone lit ($LEDS)" ;;
esac
# pidof matches the BINARY NAME. `pgrep -f "adbd|MtpDaemon"` matched the ssh shell running the
# check itself and reported a permanent false FAIL on a clean device (2026-08-30).
#
# DEV-MODE cards (enable-ssh flag set) legitimately differ (learned 2026-08-31, when this check
# false-FAILed the only card it can actually reach):
#   adbd  SURVIVES BY DESIGN in dev mode -- the wifi-less fallback (launch.sh's documented
#         carve-out). Only a non-dev card should have it dead.
#   ntpd  is respawned by ntpd-hotplug on every wlan0 address event; launch.sh and dev-net.sh
#         both kill it and hotplug wins the race eventually. Dev-only (non-dev kills wifi
#         entirely, so there is no hotplug), tolerated rather than whack-a-moled.
# MtpDaemon must be dead in BOTH modes -- it indexes the card while games stream from it.
DEVMODE=$(rsh 'test -f /mnt/SDCARD/.userdata/shared/enable-ssh && echo yes || echo no')
if [ "$DEVMODE" = "yes" ]; then EXPECT="MtpDaemon"; else EXPECT="adbd MtpDaemon ntpd"; fi
STRAY=$(rsh "for d in $EXPECT; do pidof \$d >/dev/null 2>&1 && printf '%s ' \$d; done")
if [ -n "$STRAY" ]; then
	fail "stray daemons still running: $STRAY (dev-mode=$DEVMODE)"
else
	pass "no stray daemons (dev-mode=$DEVMODE: adbd/ntpd tolerated in dev)"
fi

# --- launch <name> <secs> <cmdline> -------------------------------------------------------------
launch() {
	name=$1; secs=$2; cmdline=$3
	note "--- $name (${secs}s)"
	printf '%s\n' "$cmdline" | rsh "cat > /tmp/next" 2>/dev/null
	rsh "kill -9 \$(pidof minui.elf) 2>/dev/null"
	i=0; up=0
	while [ $i -lt 40 ]; do
		rsh "pidof minarch.elf >/dev/null 2>&1" && { up=1; break; }
		sleep 1; i=$((i+1))
	done
	[ $up -eq 1 ] || { fail "$name: minarch never started"; return 1; }
	sleep "$secs"
	if rsh "pidof minarch.elf >/dev/null 2>&1"; then
		pass "$name: ran ${secs}s, still alive"
	else
		fail "$name: minarch DIED before ${secs}s"
	fi
	rsh "dd if=/dev/fb0 of=/tmp/$name.fb bs=3145728 count=1 2>/dev/null; sync"
	rsh "cat /tmp/$name.fb" > "$ART/$name.fb" 2>/dev/null
	rsh "kill \$(pidof minarch.elf) 2>/dev/null"
	i=0
	while [ $i -lt 20 ]; do
		rsh "pidof minarch.elf >/dev/null 2>&1" || break
		sleep 1; i=$((i+1))
	done
	rsh "pidof minarch.elf >/dev/null 2>&1" && rsh "kill -9 \$(pidof minarch.elf) 2>/dev/null"
	i=0
	while [ $i -lt 25 ]; do
		rsh "pidof minui.elf >/dev/null 2>&1" && break
		sleep 1; i=$((i+1))
	done
	return 0
}

check_log() { # <name> <TAG>
	rsh "cat $LOGS/$2.txt 2>/dev/null" > "$ART/$1.log" 2>/dev/null
	if [ ! -s "$ART/$1.log" ]; then fail "$name: no log captured"; return; fi
	# GEOMETRY RECEIPT. This had no else branch, so it could only ever PASS: a log showing Smart
	# Pro geometry produced silence, not a failure, and the suite reported 21/22 green while three
	# Tools rendered at the wrong size (2026-08-30). An assertion that cannot fail is not a test.
	# Also assert the WRONG geometry is absent, because the vendor prints panel modes of its own
	# and a bare "1024x768" match can come from a line the frontend did not write.
	if grep -q "1024x768" "$ART/$1.log" 2>/dev/null && ! grep -q "1280x720" "$ART/$1.log" 2>/dev/null; then
		pass "$1: 1024x768 surface, no Smart Pro geometry"
	else
		fail "$1: geometry receipt missing or shows 1280x720"
	fi
	E=$(grep -ciE "\[ERROR\]|Segmentation|core.load_game failed|failed to load" "$ART/$1.log" 2>/dev/null)
	if [ "${E:-0}" = "0" ]; then pass "$1: no errors in log"; else fail "$1: $E error line(s) in log"; fi
}

# --- one title per SHIPPED system ---------------------------------------------------------------
note ""
note "=== per-system launch tests"

launch GBC 30 "\"$SYS/paks/Emus/GBC.pak/launch.sh\" \"$ROMS/1) Game Boy Color (GBC)/Bionic Commando - Elite Forces.gbc\"" && check_log GBC GBC
launch GBA 30 "\"$SYS/paks/Emus/GBA.pak/launch.sh\" \"$ROMS/2) Game Boy Advance (GBA)/Advance Wars 2 - Black Hole Rising.gba\"" && check_log GBA GBA
launch FC  30 "\"$SYS/paks/Emus/FC.pak/launch.sh\" \"$ROMS/3) Nintendo (FC)/1942.nes\"" && check_log FC FC
launch SUPA 30 "\"$SYS/paks/Emus/SUPA.pak/launch.sh\" \"$ROMS/4) Super Nintendo (SUPA)/ActRaiser.sfc\"" && check_log SUPA SUPA
launch MD  30 "\"$SYS/paks/Emus/MD.pak/launch.sh\" \"$ROMS/5) Sega Genesis (MD)/Adventures of Batman & Robin.md\"" && check_log MD MD

PS_ROM=$(rsh "ls \"$ROMS/6) PlayStation (PS)/Ace Combat 2/\"*.cue 2>/dev/null | head -1")
if [ -n "$PS_ROM" ]; then
	launch PS 60 "\"$SYS/paks/Emus/PS.pak/launch.sh\" \"$PS_ROM\"" && check_log PS PS
else
	fail "PS: no .cue found under Ace Combat 2"
fi

# --- TOOLS PAKS: the surface that actually broke ------------------------------------------------
# Every launch above is an Emus pak, so the suite passed while Optimize CPU / Deep Sleep / Stay
# Awake rendered at Smart Pro size. Those paks draw with their OWN binaries (clock.elf, minput.elf,
# and the confirm.elf/say.elf the others call), which live under Tools/ and are deployed by a
# DIFFERENT payload root. Assert the binaries on the card are the ones this build produced; that is
# what a stale-payload bug actually looks like from here, and it needs no screen to detect.
note ""
note "=== Tools payload freshness (the stale-binary class)"
for f in ".system/tg5040/bin/confirm.elf" ".system/tg5040/bin/say.elf" \
         ".system/tg5040/bin/settings.elf" ".system/tg5040/bin/clock.elf" "Tools/tg5040/Input.pak/minput.elf"; do
	LOCAL=""
	case "$f" in
		.system/*) LOCAL="build/PAYLOAD/${f#.system/}" ; LOCAL="build/PAYLOAD/.system/${f#.system/}" ;;
		Tools/*)   LOCAL="build/PAYLOAD/$f" ;;
	esac
	if [ ! -f "$LOCAL" ]; then
		note "  skip $f (not staged locally; run make tg5040 first)"
		continue
	fi
	L=$( (md5 -q "$LOCAL" 2>/dev/null || md5sum "$LOCAL" | cut -d' ' -f1) )
	R=$(rsh "md5sum '$SD/$f' 2>/dev/null | cut -d' ' -f1")
	if [ -z "$R" ]; then fail "$f: MISSING on device"
	elif [ "$L" = "$R" ]; then pass "$f: matches this build"
	else fail "$f: STALE on device (build $L, card $R)"
	fi
done

note ""
note "=== $PASS passed, $FAIL failed   (artifacts in $ART)"
[ "$FAIL" -eq 0 ]
