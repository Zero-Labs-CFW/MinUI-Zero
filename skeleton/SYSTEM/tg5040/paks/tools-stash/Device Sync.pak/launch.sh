#!/bin/sh
# Device Sync -- peer-to-peer save copy over a self-hosted SoftAP. No internet, no PC, no card swap.
#
# FLOW (Dan 2026-09-04/05): Send picks WHAT to copy (Customize: Saves default; Games/Recents/Settings/
# Collections optional) then finds the receiver; Receive names the sender + what is incoming, and auto-
# proceeds unless a save differs on BOTH devices (a CONFLICT the user resolves). The receiver hosts the
# hotspot (keeps its WiFi); the sender drives (drops WiFi, joins by name, pushes, then restores). Sender
# wins on settings/recents/collections; SAVES that clash are never blindly overwritten. Content, never firmware.
#
# CLARITY: every wait shows a named status via status.elf -- a no-button screen (not say.elf, which
# draws a dismiss button and reads as a decision), with a live progress bar during the copy. The only
# buttons are on real decisions. The sender only says "Reconnecting WiFi" if it HAD WiFi to begin with.

HERE=$(dirname "$0"); NET="$HERE/sync-net.sh"; ENG="$HERE/sync-engine.sh"
net(){ sh "$NET" "$@"; }
eng(){ sh "$ENG" "$@"; }

SDCARD="${SDCARD_PATH:-/mnt/SDCARD}"
export AP_IF=wlan1 STA_IF=wlan0 AP_IP=192.168.42.1 AP_PORT=8145
export DS_MODE=ask                           # receiver: same game + different save on both = a conflict
                                             # the user resolves (can't guess which has more progress)
TAB=$(printf '\t')
PORT=8145; PSK=minuizerosync
SSID=MinUI-Sync; CLIENT_IP=192.168.42.10
SERVE=/tmp/dsync-serve; LOCAL="$SDCARD"
BK_ROOT="$SDCARD/.userdata/tg5040/devicesync/backups"
STAGE="$SDCARD/.userdata/tg5040/devicesync/staging"   # receiver download staging: ON THE CARD, never /tmp (RAM)
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
# remembered peer hint (name only -- no age, the RTC can be wrong)
LP="$SDCARD/.userdata/tg5040/devicesync/last-peer"; HINT=""
if [ -s "$LP" ]; then lpn=$(cut -d'|' -f1 "$LP" 2>/dev/null); [ -n "$lpn" ] && HINT="

Last: received from $lpn"; fi
confirm.elf "Device Sync

Copy your saves to another
device. No internet needed.$HINT" "SEND" "$MID" "RECEIVE"
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
	trap 'status_off; net ap-down >/dev/null 2>&1; rm -rf "$SERVE" "$STAGE"' EXIT INT TERM HUP
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

	status "Checking what is new..."           # the plan below stats every file we already have; say so
	SENDER=$(wget -q -O - "http://$CLIENT_IP:$PORT/_dsync_name" 2>/dev/null); [ -z "$SENDER" ] && SENDER="the other device"
	SCOPE_LABEL=$(wget -q -O - "http://$CLIENT_IP:$PORT/_dsync_scope" 2>/dev/null); [ -z "$SCOPE_LABEL" ] && SCOPE_LABEL="Saves"
	# plan in "ask" mode: new saves = ADD (auto); same game + different save on both = CONFLICT (user decides)
	PLAN=$(eng plan-net "$MF" "$LOCAL")
	NADD=$(printf '%s\n' "$PLAN" | grep -c "^ADD$TAB")
	CONFLICTS=$(printf '%s\n' "$PLAN" | grep "^CONFLICT$TAB" | cut -f2-)
	NCON=$(printf '%s\n' "$CONFLICTS" | grep -c .)
	dbg "recv sender=$SENDER add=$NADD conflicts=$NCON"
	status_off
	if [ "$((NADD + NCON))" -eq 0 ]; then say.elf "Already in sync with
$SENDER.

Nothing new to copy."; exit 0; fi

	# Games can be gigabytes: stage downloads ON THE CARD (never /tmp, which is RAM on a 1 GB device), and
	# refuse up front if the card cannot hold the incoming delta (Dan 2026-09-05). Need = every file we
	# will download (ADD + CONFLICT), +10% and 50 MB headroom for the per-file tmp copy during apply.
	rm -rf "$STAGE"; mkdir -p "$STAGE"; export TMPDIR="$STAGE"
	NEED_KB=$(printf '%s\n' "$PLAN" | grep -E "^(ADD|CONFLICT)$TAB" | cut -f2- \
		| awk -F"$TAB" 'NR==FNR{w[$0]=1;next} ($1 in w){s+=$2} END{printf "%d",(s+1023)/1024}' - "$MF")
	FREE_KB=$(df -k "$SDCARD" 2>/dev/null | awk 'NR==2{print $4}')
	dbg "recv need=${NEED_KB:-?}KB free=${FREE_KB:-?}KB"
	if [ -n "$FREE_KB" ] && [ "$FREE_KB" -lt $((NEED_KB + NEED_KB/10 + 51200)) ] 2>/dev/null; then
		say.elf "Not enough space on this card.

Needs about $((NEED_KB/1024)) MB, but only
$((FREE_KB/1024)) MB is free.

Nothing was copied."; exit 0
	fi

	TAKE=/tmp/dsync-take; : > "$TAKE"; export DS_TAKE="$TAKE"
	if [ "$NCON" -eq 0 ]; then
		# nothing you already have is overwritten -> zero-tap cancelable countdown
		printf 'Receiving %s\nfrom %s\n\n%s new item(s) will copy over.\nNothing you already have changes.' "$SCOPE_LABEL" "$SENDER" "$NADD" > "$SMSG"
		status.elf "$SMSG" --countdown 6 --cancel-b
		[ "$?" = 0 ] || { say.elf "Cancelled.

Nothing was copied."; exit 0; }
	else
		# same game, different save on both. The tool cannot know which has more progress, so ask.
		confirm.elf "$NCON game(s) have a different
save here and on $SENDER
(like a character you built up).

Keep which copy?" "TAKE THEIRS" "KEEP MINE" "DECIDE EACH"
		case "$?" in
			0) printf '%s\n' "$CONFLICTS" > "$TAKE" ;;                 # take all from sender
			1) : > "$TAKE" ;;                                          # keep all mine (conflicts skipped)
			2) printf '%s\n' "$CONFLICTS" | while IFS= read -r cr; do
					[ -n "$cr" ] || continue
					nm=$(basename "$cr" 2>/dev/null); nm=${nm%.*}
					confirm.elf "$nm

Different here and on $SENDER.
Which copy do you keep?" "TAKE THEIRS" "KEEP MINE"
					[ "$?" = 0 ] && echo "$cr" >> "$TAKE"
				done ;;
			*) exit 0 ;;
		esac
		dbg "recv resolved take=$(grep -c . "$TAKE" 2>/dev/null)/$NCON"
	fi

	status "Copying from $SENDER..."
	BK="$BK_ROOT/$(ts)"
	net pull "$CLIENT_IP" "$PORT" "$LOCAL" "$BK" >/tmp/dsync-pull.log 2>&1
	cat /tmp/dsync-pull.log >> "$LOGF" 2>/dev/null
	echo "$BK" > "$LAST"; eng prune "$BK_ROOT" 5 >/dev/null 2>&1
	printf '%s|%s' "$SENDER" "$(date +%s 2>/dev/null)" > "$SDCARD/.userdata/tg5040/devicesync/last-peer" 2>/dev/null
	APPLIED=$(wc -l < "$BK/ops.log" 2>/dev/null | tr -d ' ')
	dbg "recv applied=$APPLIED $(grep -o 'pull: [0-9]*/[0-9]*' /tmp/dsync-pull.log | head -1)"
	status_off
	if grep -q 'gave up on' /tmp/dsync-pull.log 2>/dev/null; then
		printf 'Partly done.\n\nGot %s item(s) from %s.\nRun Device Sync again to finish.' "${APPLIED:-0}" "$SENDER" > "$SMSG"
	else
		printf 'Done!\n\nGot %s item(s) from\n%s.\n\nUndo from the Device Sync menu.' "${APPLIED:-0}" "$SENDER" > "$SMSG"
	fi
	status.elf "$SMSG" --timeout 5
	exit 0
fi

# ============================ SEND: pick scope, publish name, join, serve ============================
# 1) the sender CHOOSES what to send (Customize). Runs before any radio change, so a cancel is a clean
#    no-op. Default = Saves only (the common case stays two taps: SEND then START). pick.elf prints the
#    KEY of each ticked row; the case below is the only thing that trusts those tokens, so stray stdout
#    from GFX init cannot smuggle in a scope.
# Collections is offered ONLY if the user actually has some, and it defaults ON then (Dan 2026-09-05:
# "we can do Collections too if they exist"). No collections -> the row is omitted, not shown empty.
COLL_ARG=""
if [ -d "$LOCAL/Collections" ] && [ -n "$(ls -A "$LOCAL/Collections" 2>/dev/null)" ]; then
	COLL_ARG="collections:Collections:1"
fi
if command -v pick.elf >/dev/null 2>&1; then
	CHOICE=$(pick.elf "What to send?" \
		"saves:Saves:1" \
		"games:Games (ROMs):0" \
		"recents:Recently Played:0" \
		"configs:Settings:0" \
		$COLL_ARG)
	[ "$?" = 0 ] || exit 0
else
	# picker binary not deployed: fall back to the safe default rather than a silent no-op
	CHOICE=saves; [ -n "$COLL_ARG" ] && CHOICE="saves
collections"
fi
SCOPE=""; LABELS=""
for k in $CHOICE; do case "$k" in
	saves)       SCOPE="$SCOPE Saves"; LABELS="$LABELS, Saves"
	             # save states live per-core under .userdata/shared/<tag>-<core>/ -- fold them into "Saves".
	             # Require an actual .st* file: skips empty core dirs and any hyphenated non-state dir. The
	             # dot-glob rule already excludes .minui and the ._* / wifi.conf / *_host_key siblings.
	             for d in "$LOCAL"/.userdata/shared/*-*/; do [ -d "$d" ] || continue; ls "$d"*.st* >/dev/null 2>&1 || continue; r=${d#"$LOCAL"/}; SCOPE="$SCOPE ${r%/}"; done ;;
	games)       SCOPE="$SCOPE Roms"; LABELS="$LABELS, Games" ;;
	recents)     SCOPE="$SCOPE .userdata/shared/.minui/recent.txt"; LABELS="$LABELS, Recently Played" ;;
	configs)     LABELS="$LABELS, Settings"
	             # per-game + per-core configs under .userdata/tg5040/<tag>-<core>/. Require an actual .cfg:
	             # this is what distinguishes a real config dir from app state that also has a hyphen
	             # (e.g. nextui-pak-store) and from our own no-hyphen devicesync backups.
	             for d in "$LOCAL"/.userdata/tg5040/*-*/; do
	                 [ -d "$d" ] || continue
	                 n=${d%/}; n=${n##*/}; case "$n" in nextui-pak-store) continue ;; esac   # app state that happens to carry a .cfg (seen on the Brick 2026-09-05)
	                 ls "$d"*.cfg >/dev/null 2>&1 || continue
	                 r=${d#"$LOCAL"/}; SCOPE="$SCOPE ${r%/}"
	             done ;;
	collections) SCOPE="$SCOPE Collections"; LABELS="$LABELS, Collections" ;;
esac; done
LABELS=${LABELS#, }
if [ -z "$SCOPE" ]; then say.elf "Nothing selected to send.

Choose at least one item."; exit 0; fi
dbg "send scope: $SCOPE"

# 2) now touch the radio. Capture whether we HAD real WiFi, so we only "reconnect" if there was one.
HOMEIP=$(ip -4 addr show "$STA_IF" 2>/dev/null | sed -n 's/.*inet \([0-9.]*\).*/\1/p' | head -1)
case "$HOMEIP" in 192.168.42.*|"") HAD_WIFI=0 ;; *) HAD_WIFI=1 ;; esac
# The home-WiFi config is saved INSIDE join (the only thing that changes the radio), and restore_wifi
# acts only if that save exists. So an abort before join leaves WiFi exactly as it was. Saving it
# earlier here was tried on 2026-09-05 and was WRONG: it made the exit trap restart wpa_supplicant on
# a radio we never touched, which knocked the Brick off its network twice.
teardown_send(){
	net stop-serve >/dev/null 2>&1
	if [ "$HAD_WIFI" = 1 ]; then net restore-wifi >/dev/null 2>&1; else net wifi-off >/dev/null 2>&1; fi
	rm -rf "$SERVE"
}
trap 'status_off; teardown_send' EXIT INT TERM HUP
dbg "send name=$NAME had_wifi=$HAD_WIFI home=$HOMEIP"

# the file list can take a moment with Games selected -- NEVER a black screen (2026-09-05: it was)
status "Preparing your files..."
net build-export "$LOCAL" "$SERVE" $SCOPE >/dev/null 2>&1
echo "$NAME" > "$SERVE/_dsync_name"           # so the receiver can name us in its confirm
printf '%s' "$LABELS" > "$SERVE/_dsync_scope" # so the receiver can name WHAT it is getting

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
