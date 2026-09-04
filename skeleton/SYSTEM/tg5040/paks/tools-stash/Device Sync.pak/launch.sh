#!/bin/sh
# Device Sync -- peer-to-peer save copy over a self-hosted SoftAP. No internet, no PC, no card swap.
#
# FLOW (Dan 2026-09-04): one tap to Send, one tap to Receive; the receiver CONFIRMS which named device
# it is getting saves from before writing anything. The receiver hosts the hotspot (keeps its WiFi);
# the sender drives (drops WiFi, joins by name, pushes, then restores). Push semantics: the sender's
# saves win (clock-independent). Content only, never firmware.
#
# CLARITY: every wait shows a named status via status.elf -- a no-button screen (not say.elf, which
# draws a dismiss button and reads as a decision), with a live progress bar during the copy. The only
# buttons are on real decisions. The sender only says "Reconnecting WiFi" if it HAD WiFi to begin with.

HERE=$(dirname "$0"); NET="$HERE/sync-net.sh"; ENG="$HERE/sync-engine.sh"
net(){ sh "$NET" "$@"; }
eng(){ sh "$ENG" "$@"; }

SDCARD="${SDCARD_PATH:-/mnt/SDCARD}"
export AP_IF=wlan1 STA_IF=wlan0 AP_IP=192.168.42.1 AP_PORT=8145
export DS_MODE=push                          # Send is directional: the sender's saves win (clock-safe)
PORT=8145; PSK=minuizerosync
SSID=MinUI-Sync; CLIENT_IP=192.168.42.10
SERVE=/tmp/dsync-serve; LOCAL="$SDCARD"
BK_ROOT="$SDCARD/.userdata/tg5040/devicesync/backups"
LAST="$SDCARD/.userdata/tg5040/devicesync/last-sync"
LOGF="$SDCARD/.userdata/tg5040/logs/devicesync.txt"
mkdir -p "$(dirname "$LOGF")" "$(dirname "$LAST")" 2>/dev/null

# human-friendly model name (Trimui Brick / Brick Pro / Smart Pro) -- how the fork already detects it
NAME="${TRIMUI_MODEL}"
[ -z "$NAME" ] && NAME=$(strings /usr/trimui/bin/MainUI 2>/dev/null | grep '^Trimui' | head -1)
[ -z "$NAME" ] && NAME="a Trimui"

dbg(){ echo "$(date '+%H:%M:%S') [${MODE:-?}] $*" >> "$LOGF" 2>/dev/null; }
ts(){ date +%Y%m%d-%H%M%S 2>/dev/null || echo run; }

# --- no-button status screen (status.elf), updated live via a message file; progress via a 2nd file ---
SMSG=/tmp/dsync-status.msg; SPROG=/tmp/dsync-status.prog
export DS_PROGRESS="$SPROG"                   # pull writes "<done>/<total>" here; status.elf draws the bar
status(){ echo "$1" > "$SMSG"; : > "$SPROG"; if ! pidof status.elf >/dev/null 2>&1; then status.elf "$SMSG" "$SPROG" >/dev/null 2>&1 & fi; }
status_off(){ killall status.elf 2>/dev/null; rm -f "$SMSG" "$SPROG"; }

dbg "==== launch name=$NAME ===="
if [ -s "$LAST" ] && [ -d "$(cat "$LAST" 2>/dev/null)" ]; then MID="UNDO LAST"; else MID="CANCEL"; fi
confirm.elf "Device Sync

Copy your saves to another
device. No internet needed." "SEND" "$MID" "RECEIVE"
case "$?" in
	0) MODE=send ;;
	2) MODE=receive ;;
	1)  if [ "$MID" = "UNDO LAST" ]; then
			BK=$(cat "$LAST" 2>/dev/null)
			confirm.elf "Undo the last sync?

Puts this device back exactly
how it was before." "UNDO" "BACK" || exit 0
			eng undo "$SDCARD" "$BK" >/dev/null 2>&1; rm -f "$LAST"
			say.elf "Done. The last sync was undone."
		fi
		exit 0 ;;
	*) exit 0 ;;
esac

# ============================ RECEIVE: open, confirm sender, pull ============================
if [ "$MODE" = receive ]; then
	# receiver keeps its own WiFi (concurrent AP), so it never needs to reconnect -- just drop the AP.
	trap 'status_off; net ap-down >/dev/null 2>&1; rm -rf "$SERVE"' EXIT INT TERM HUP
	net ap-up "$SSID" "$PSK" >/dev/null 2>&1
	dbg "recv ap-up hostapd=$(pidof hostapd >/dev/null 2>&1 && echo up || echo DOWN)"
	if ! pidof hostapd >/dev/null 2>&1; then status_off; say.elf "Could not open to receive.
Please try again."; exit 1; fi

	status "Ready to receive.

Waiting for the other device.
On it, choose Send."
	MF=/tmp/dsync-recv-manifest; i=0; ok=0
	while [ "$i" -lt 150 ]; do
		if [ "$(net sta-count)" -ge 1 ] && wget -q -O "$MF" "http://$CLIENT_IP:$PORT/_dsync_manifest" 2>/dev/null && [ -s "$MF" ]; then ok=1; break; fi
		sleep 2; i=$((i+2))
	done
	if [ "$ok" != 1 ]; then status_off; say.elf "No device connected.

Make sure the other device
chose Send, then try again."; exit 0; fi

	SENDER=$(wget -q -O - "http://$CLIENT_IP:$PORT/_dsync_name" 2>/dev/null); [ -z "$SENDER" ] && SENDER="the other device"
	N=$(eng delta "$MF" "$LOCAL" | grep -c .)
	dbg "recv sender=$SENDER delta N=$N"
	status_off
	if [ "$N" -eq 0 ]; then say.elf "Already in sync with
$SENDER.

Nothing new to copy."; exit 0; fi

	confirm.elf "Get saves from
$SENDER?

$N file(s) will copy. Nothing
is deleted, and this is undoable." "YES" "NO"
	[ "$?" = 0 ] || exit 0

	status "Copying from $SENDER..."
	BK="$BK_ROOT/$(ts)"
	net pull "$CLIENT_IP" "$PORT" "$LOCAL" "$BK" >/tmp/dsync-pull.log 2>&1
	cat /tmp/dsync-pull.log >> "$LOGF" 2>/dev/null
	echo "$BK" > "$LAST"; eng prune "$BK_ROOT" 5 >/dev/null 2>&1
	status_off
	dbg "recv $(grep -o 'pull: [0-9]*/[0-9]*' /tmp/dsync-pull.log | head -1)"
	say.elf "Done!

Got saves from $SENDER.
Undo any time from the
Device Sync menu."
	exit 0
fi

# ============================ SEND: publish name, join, serve ============================
# capture whether we HAD a real WiFi connection, so we only "reconnect" if there was one to restore
HOMEIP=$(ip -4 addr show "$STA_IF" 2>/dev/null | sed -n 's/.*inet \([0-9.]*\).*/\1/p' | head -1)
case "$HOMEIP" in 192.168.42.*|"") HAD_WIFI=0 ;; *) HAD_WIFI=1 ;; esac
teardown_send(){
	net stop-serve >/dev/null 2>&1
	if [ "$HAD_WIFI" = 1 ]; then net restore-wifi >/dev/null 2>&1; else net wifi-off >/dev/null 2>&1; fi
	rm -rf "$SERVE"
}
trap 'status_off; teardown_send' EXIT INT TERM HUP
dbg "send name=$NAME had_wifi=$HAD_WIFI home=$HOMEIP"

net build-export "$LOCAL" "$SERVE" Saves Collections >/dev/null 2>&1
echo "$NAME" > "$SERVE/_dsync_name"           # so the receiver can name us in its confirm

status "Looking for a device to
send to.

Make sure it chose Receive."
IP=$(net join "$SSID" "$PSK")
dbg "send join ip=$IP"
if [ -z "$IP" ] || ! ping -c1 -W2 "$AP_IP" >/dev/null 2>&1; then
	status_off; say.elf "Could not find a device.

On the other one, choose
Receive first, then try again."; exit 0
fi
net serve "$SERVE" "$PORT" >/dev/null 2>&1
status "Sending your saves...

Keep this until the other
device is done."
i=0; while ping -c1 -W2 "$AP_IP" >/dev/null 2>&1 && [ "$i" -lt 240 ]; do sleep 3; i=$((i+3)); done
dbg "send: receiver hotspot gone -> done"
# only show "Reconnecting" if we actually had WiFi; otherwise just leave the radio off
if [ "$HAD_WIFI" = 1 ]; then status "Reconnecting your WiFi..."; fi
teardown_send
status_off
trap - EXIT INT TERM HUP
dbg "send done"
exit 0
