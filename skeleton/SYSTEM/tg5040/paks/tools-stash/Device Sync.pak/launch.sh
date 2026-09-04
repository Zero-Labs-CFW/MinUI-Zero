#!/bin/sh
# Device Sync -- peer-to-peer save/rom sync over a self-hosted SoftAP. No internet, no PC, no card swap.
#
# LEAN UX (Dan 2026-09-04): least friction. Fixed passphrase, device-name SSID; the receiver auto-joins
# the single sender it finds. The ONE security gate is a single ALLOW tap on the sender -- httpd starts
# serving only AFTER the sender approves the connected device. Content only (saves/roms/collections),
# never firmware (see sync-engine.sh / the design doc).
#
# UI is modal: confirm.elf returns A=0 B=1 X=2; say.elf blocks until A/B. "Waiting" states poll
# silently between dialogs. The receiver ALWAYS restores home wifi on exit via a trap.
#
# STATUS: first draft, UI not yet exercised on a device (needs two Bricks + a person at the screen).
# The transport + engine underneath are hardware-proven (Phase 2b/2c).

HERE=$(dirname "$0")
NET="$HERE/sync-net.sh"; ENG="$HERE/sync-engine.sh"
net() { sh "$NET" "$@"; }
eng() { sh "$ENG" "$@"; }

SDCARD="${SDCARD_PATH:-/mnt/SDCARD}"
export AP_IF=wlan1 STA_IF=wlan0 AP_IP=192.168.42.1 AP_PORT=8145
PORT=8145
PSK=minuizerosync                       # fixed; NOT the security boundary (the ALLOW tap is)
MODEL=$(cat /proc/device-tree/model 2>/dev/null | tr -d '\000' | tr -cs 'A-Za-z0-9' '-' | sed 's/^-//;s/-$//'); [ -z "$MODEL" ] && MODEL=Device
SSID="MinUI-Sync-$MODEL"
SERVE=/tmp/dsync-serve
LOCAL="$SDCARD"                         # sync into the live card
BK_ROOT="$SDCARD/.userdata/tg5040/devicesync/backups"
INPROG="$SDCARD/.userdata/shared/dsync-inprogress"

scope_dirs() { case "$1" in all) echo "Roms Saves Collections" ;; *) echo "Saves Collections" ;; esac; }
ts() { date +%Y%m%d-%H%M%S 2>/dev/null || echo run; }

# ============================== top level: Send or Receive ==============================
confirm.elf "Device Sync

Move saves and games between
your devices over WiFi.
No internet needed." "SEND" "CANCEL" "RECEIVE"
case "$?" in 0) MODE=send ;; 2) MODE=receive ;; *) exit 0 ;; esac

confirm.elf "What should sync?

Saves is quick. Everything also
copies your games and can take
a while." "SAVES" "CANCEL" "EVERYTHING"
case "$?" in 0) SCOPE=saves ;; 2) SCOPE=all ;; *) exit 0 ;; esac
DIRS=$(scope_dirs "$SCOPE")

# ============================== SENDER ==============================
if [ "$MODE" = send ]; then
	net ap-up "$SSID" "$PSK" >/dev/null 2>&1
	if ! pidof hostapd >/dev/null 2>&1; then
		net ap-down >/dev/null 2>&1
		say.elf "Could not start the hotspot.
Please try again."
		exit 1
	fi
	say.elf "Hotspot ready.

On the OTHER device, open
Device Sync and choose Receive.

Press A once you have."
	# wait for a device to associate (~40s)
	i=0; while [ "$(net sta-count)" -lt 1 ] && [ "$i" -lt 40 ]; do sleep 1; i=$((i+1)); done
	if [ "$(net sta-count)" -lt 1 ]; then
		net ap-down >/dev/null 2>&1
		say.elf "No device connected.

Make sure the other device chose
Receive, then try again."
		exit 0
	fi
	confirm.elf "A device connected.

Allow it to copy from
this device?" "ALLOW" "DENY"
	if [ "$?" != 0 ]; then
		net ap-down >/dev/null 2>&1
		say.elf "Denied. Nothing was shared."
		exit 0
	fi
	# serve ONLY after Allow
	net build-export "$LOCAL" "$SERVE" $DIRS >/dev/null 2>&1
	net serve "$SERVE" "$PORT" >/dev/null 2>&1
	say.elf "Sharing now.

The other device is copying.
This screen returns when it
finishes. (Press A to dismiss.)"
	# wait for the receiver to finish and leave the AP (or ~3 min timeout)
	i=0; while [ "$(net sta-count)" -ge 1 ] && [ "$i" -lt 180 ]; do sleep 2; i=$((i+2)); done
	net stop-serve >/dev/null 2>&1; net ap-down >/dev/null 2>&1; rm -rf "$SERVE"
	say.elf "Sync finished. Hotspot off."
	exit 0
fi

# ============================== RECEIVER ==============================
# home wifi ALWAYS comes back, however we exit; the flag is a boot-time marker
cleanup_recv() { net restore-wifi >/dev/null 2>&1; rm -f "$INPROG"; }
trap cleanup_recv EXIT INT TERM HUP

FOUND=$(net scan | head -1)
if [ -z "$FOUND" ]; then
	say.elf "No sender found.

On the other device, open
Device Sync and choose Send,
then try Receive again."
	exit 0
fi
mkdir -p "$(dirname "$INPROG")"; touch "$INPROG"
net join "$FOUND" "$PSK" >/dev/null 2>&1

# wait for the sender to tap Allow (its httpd + manifest appear), ~45s
MF=/tmp/dsync-recv-manifest
i=0; ok=0
while [ "$i" -lt 45 ]; do
	if wget -q -O "$MF" "http://$AP_IP:$PORT/_dsync_manifest" 2>/dev/null && [ -s "$MF" ]; then ok=1; break; fi
	sleep 1; i=$((i+1))
done
if [ "$ok" != 1 ]; then
	say.elf "Could not reach the sender.

It may not have tapped Allow yet.
Please try again."
	exit 0
fi

N=$(eng delta "$MF" "$LOCAL" | grep -c .)
if [ "$N" -eq 0 ]; then
	say.elf "Already in sync.

Nothing new to copy."
	exit 0
fi
confirm.elf "Ready to sync.

$N file(s) to copy over.
Older versions are backed up;
nothing is deleted." "SYNC" "CANCEL"
[ "$?" = 0 ] || exit 0

BK="$BK_ROOT/$(ts)"
net pull "$AP_IP" "$PORT" "$LOCAL" "$BK" >/tmp/dsync-pull.log 2>&1
DONE=$(grep -o 'pull: [0-9]*/[0-9]* verified' /tmp/dsync-pull.log | head -1)
[ -z "$DONE" ] && DONE="sync attempted"

confirm.elf --ok "Sync Complete" "$DONE and applied.
Older versions were backed up.

Keep these changes?" "" "KEEP" "UNDO"
if [ "$?" = 2 ]; then
	eng undo "$LOCAL" "$BK" >/dev/null 2>&1
	say.elf "Changes undone.

Your device is back as it was."
fi
eng prune "$BK_ROOT" 5 >/dev/null 2>&1
say.elf "Done. Reconnecting your WiFi..."
exit 0   # cleanup_recv (restore wifi) runs on EXIT
