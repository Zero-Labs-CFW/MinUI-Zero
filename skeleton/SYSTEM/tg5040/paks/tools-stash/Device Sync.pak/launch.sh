#!/bin/sh
# Device Sync -- peer-to-peer save/rom copy over a self-hosted SoftAP. No internet, no PC, no card swap.
#
# MODEL (Dan 2026-09-04): receiver-open / sender-drives, and NO scanning (the scan-while-connected step
# is what failed). The RECEIVER hosts a fixed-name hotspot "MinUI-Sync" and just waits + pulls; it keeps
# home wifi via the concurrent AP (no scan needed on this side). The SENDER picks what to send, drops
# its own wifi, joins "MinUI-Sync" BY NAME (wpa_supplicant finds it -- reliable), serves its export, then
# reconnects. No press-A, no Allow. A backgrounded say.elf keeps a status on screen so it is never black.
# Data flows sender -> receiver; the receiver applies with backup + undo. Content only, never firmware.

HERE=$(dirname "$0"); NET="$HERE/sync-net.sh"; ENG="$HERE/sync-engine.sh"
net(){ sh "$NET" "$@"; }
eng(){ sh "$ENG" "$@"; }

SDCARD="${SDCARD_PATH:-/mnt/SDCARD}"
export AP_IF=wlan1 STA_IF=wlan0 AP_IP=192.168.42.1 AP_PORT=8145
export DS_MODE=push                       # Send is directional: the SENDER's saves win on any diff
                                          # (clock-independent -- immune to these devices' bad RTCs)
PORT=8145; PSK=minuizerosync
SSID=MinUI-Sync                          # FIXED name: sender joins by name, no scan
CLIENT_IP=192.168.42.10                  # sender's DHCP address (first in the receiver's udhcpd range)
SERVE=/tmp/dsync-serve
LOCAL="$SDCARD"
BK_ROOT="$SDCARD/.userdata/tg5040/devicesync/backups"
LOGF="$SDCARD/.userdata/tg5040/logs/devicesync.txt"; mkdir -p "$(dirname "$LOGF")" 2>/dev/null
dbg(){ echo "$(date '+%H:%M:%S') [${MODE:-?}] $*" >> "$LOGF" 2>/dev/null; }
ts(){ date +%Y%m%d-%H%M%S 2>/dev/null || echo run; }

# on-screen status during silent poll waits (backgrounded say.elf, replaced/cleared as we go) -> never black
STPID=
status(){ [ -n "$STPID" ] && kill "$STPID" 2>/dev/null; say.elf "$1" >/dev/null 2>&1 & STPID=$!; }
status_off(){ [ -n "$STPID" ] && kill "$STPID" 2>/dev/null; STPID=; }

scope_dirs(){ case "$1" in all) echo "Roms Saves Collections" ;; *) echo "Saves Collections" ;; esac; }

dbg "==== launch (receiver-open model) ===="
confirm.elf "Device Sync

Copy saves and games to
another device over WiFi.
No internet needed." "SEND" "CANCEL" "RECEIVE"
case "$?" in 0) MODE=send ;; 2) MODE=receive ;; *) exit 0 ;; esac

# ============================== RECEIVER: open, wait, pull ==============================
if [ "$MODE" = receive ]; then
	trap 'status_off; net ap-down >/dev/null 2>&1; rm -rf "$SERVE"' EXIT INT TERM HUP
	net ap-up "$SSID" "$PSK" >/dev/null 2>&1
	dbg "recv ap-up hostapd=$(pidof hostapd >/dev/null 2>&1 && echo up || echo DOWN) wlan0home=$(ip -4 addr show wlan0 2>/dev/null | sed -n 's/.*inet \([0-9.]*\).*/\1/p' | head -1)"
	if ! pidof hostapd >/dev/null 2>&1; then
		say.elf "Could not open for receiving.
Please try again."
		exit 1
	fi
	status "Open to receive.

Waiting for the other device.
On it, choose Send."
	# wait for the sender to associate (~2 min)
	i=0; while [ "$(net sta-count)" -lt 1 ] && [ "$i" -lt 120 ]; do sleep 2; i=$((i+2)); done
	if [ "$(net sta-count)" -lt 1 ]; then
		status_off
		say.elf "No device connected.

Make sure the other device
chose Send, then try again."
		exit 0
	fi
	dbg "recv: client joined; waiting for its files"
	status "Connected.

Getting the file list..."
	# wait for the sender's httpd + manifest (~90s)
	MF=/tmp/dsync-recv-manifest; i=0; ok=0
	while [ "$i" -lt 90 ]; do
		if wget -q -O "$MF" "http://$CLIENT_IP:$PORT/_dsync_manifest" 2>/dev/null && [ -s "$MF" ]; then ok=1; break; fi
		sleep 2; i=$((i+2))
	done
	dbg "recv manifest ok=$ok"
	if [ "$ok" != 1 ]; then
		status_off
		say.elf "The other device did not
share anything. Try again."
		exit 0
	fi
	N=$(eng delta "$MF" "$LOCAL" | grep -c .)
	dbg "recv delta N=$N"
	if [ "$N" -eq 0 ]; then
		status_off
		say.elf "Already in sync.

Nothing new to copy."
		exit 0
	fi
	status "Copying $N file(s)..."
	BK="$BK_ROOT/$(ts)"
	net pull "$CLIENT_IP" "$PORT" "$LOCAL" "$BK" >/tmp/dsync-pull.log 2>&1
	cat /tmp/dsync-pull.log >> "$LOGF" 2>/dev/null
	DONE=$(grep -o 'pull: [0-9]*/[0-9]* verified' /tmp/dsync-pull.log | head -1); [ -z "$DONE" ] && DONE="done"
	dbg "recv pull [$DONE]"
	status_off
	confirm.elf --ok "Sync Complete" "$DONE and applied.
Older versions were backed up.

Keep these changes?" "" "KEEP" "UNDO"
	if [ "$?" = 2 ]; then
		eng undo "$LOCAL" "$BK" >/dev/null 2>&1
		say.elf "Changes undone.

Your device is back as it was."
	fi
	eng prune "$BK_ROOT" 5 >/dev/null 2>&1
	# ap-down (trap) ends the session; the sender sees the hotspot vanish and reconnects
	exit 0
fi

# ============================== SENDER: pick scope, join, serve ==============================
confirm.elf "What should send?

SAVES: your save files only (fast).
GAMES TOO: also the game files
themselves (large, can be slow)." "SAVES" "CANCEL" "GAMES TOO"
case "$?" in 0) SCOPE=saves ;; 2) SCOPE=all ;; *) exit 0 ;; esac
DIRS=$(scope_dirs "$SCOPE")
trap 'status_off; net stop-serve >/dev/null 2>&1; net restore-wifi >/dev/null 2>&1; rm -rf "$SERVE"' EXIT INT TERM HUP
dbg "send scope=$SCOPE dirs=[$DIRS]"

net build-export "$LOCAL" "$SERVE" $DIRS >/dev/null 2>&1
status "Looking for an open device.

Make sure the other device
chose Receive."
IP=$(net join "$SSID" "$PSK")            # drops home wifi, joins the receiver by name (patient)
dbg "send join ip=$IP pingAP=$(ping -c1 -W2 $AP_IP >/dev/null 2>&1 && echo OK || echo FAIL)"
if [ -z "$IP" ] || ! ping -c1 -W2 "$AP_IP" >/dev/null 2>&1; then
	status_off
	say.elf "Could not find an open device.

On the other device, choose
Receive first, then try again."
	exit 0
fi
net serve "$SERVE" "$PORT" >/dev/null 2>&1
dbg "send serving httpd=$(pidof httpd >/dev/null 2>&1 && echo up || echo DOWN)"
status "Sending...

Keep this screen up until the
other device says it is done."
# wait until the receiver tears down its hotspot (its signal that it finished), ~4 min
i=0; while ping -c1 -W2 "$AP_IP" >/dev/null 2>&1 && [ "$i" -lt 240 ]; do sleep 3; i=$((i+3)); done
dbg "send: receiver hotspot gone after ${i}s -> done"
status "Reconnecting your WiFi..."        # keep a screen up WHILE it reconnects (not after)
net stop-serve >/dev/null 2>&1
net restore-wifi >/dev/null 2>&1
status_off
dbg "send restored wlan0=$(ip -4 addr show wlan0 2>/dev/null | sed -n 's/.*inet \([0-9.]*\).*/\1/p' | head -1)"
say.elf "Done. Your saves were sent."
exit 0   # trap re-runs restore-wifi as a safety net (idempotent)
