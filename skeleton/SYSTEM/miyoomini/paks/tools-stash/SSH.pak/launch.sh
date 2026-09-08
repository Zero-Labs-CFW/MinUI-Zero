#!/bin/sh
# SSH, DEV CARDS ONLY (Dan, 2026-09-08). Appears in Tools only when devmode.txt is at the card
# root — a user card never gets a way to start a daemon, so the fork stays runs-cold and quiet.
#
# THIS IS NOT A NEW DESIGN. It follows Onion, the MMP's dominant CFW, which is where this device's
# working SSH came from in the first place: Dan's old card carried a community pak wrapping Onion's
# dropbear (its log printed "Dropbear server v2022.83", and Onion's binary is 2022.83-MM). Onion
# exposes SSH as a TOGGLE (Apps > Tweaks > Network > SSH), starts `dropbear -R -B`, requires wifi,
# and kills the daemon when wifi drops. We match that shape. The one thing we add is an on-screen
# result, because the boot-time block we shipped in v1.7.5 failed silently and cost an evening.
#
# WHY A MENU ENTRY AT ALL, when MinUI.pak/launch.sh already starts sshd on a devmode card: that
# block produced NO output on 2026-09-08 — not even its own first log line — with both gate files
# verified present afterwards and the block itself verified correct under real busybox ash. A card
# in a reader cannot explain a boot it did not witness. This pak does not care why: it runs in
# front of you, on demand, and says what happened.
#
# BINARY NOTE: our .system/miyoomini/bin/dropbearmulti links exactly the same three libraries as
# Onion's known-good binary (libc.so.6, libcrypt.so.1, libutil.so.1, interpreter
# /lib/ld-linux-armhf.so.3), so "it cannot exec here" is already ruled out.

# Onion's own prebuilt dropbear is tried FIRST: it is the exact binary that gave this hardware ssh
# historically, so it is the known-good artifact, not a hopeful port. Our stock build is the
# fallback. (Both link the same three libraries, verified 2026-09-08.)
ONION="$SYSTEM_PATH/bin/dropbear-onion"
BIN="$SYSTEM_PATH/bin/dropbearmulti"
SSH_DIR="$USERDATA_PATH/SSH"
HK="$SSH_DIR/dropbear_ed25519_host_key"
LOG="$LOGS_PATH/ssh-pak.txt"
mkdir -p "$SSH_DIR" "$LOGS_PATH" 2>/dev/null

ip_now() { ip -4 addr show wlan0 2>/dev/null | sed -n 's/.*inet \([0-9.]*\).*/\1/p' | head -1; }
# LISTENING, not merely "a process called dropbear exists". The old check gave a false positive when
# dropbear forked and then died (bad key, bind failure) — pgrep saw the corpse, we said "running",
# and the user got a success screen while port 22 was refused. Ask the kernel who is bound to :22.
# /proc/net/tcp holds the local port in hex; 0016 = 22. Fall back to pgrep only if that file is
# somehow unreadable.
listening() {
	if [ -r /proc/net/tcp ]; then
		awk 'NR>1{split($2,a,":"); if (a[2]=="0016" && $4=="0A") {found=1}} END{exit !found}' /proc/net/tcp && return 0
		[ -r /proc/net/tcp6 ] && awk 'NR>1{split($2,a,":"); if (a[2]=="0016" && $4=="0A") {found=1}} END{exit !found}' /proc/net/tcp6 && return 0
		return 1
	fi
	pgrep dropbear >/dev/null 2>&1
}
# Launch fully detached: new session, all three fds to /dev/null, background. Without this the
# daemon inherits the pak's controlling terminal and stdout (the framebuffer console), and a
# daemonized-but-unhappy dropbear holding those fds is what made say.elf/confirm.elf render nothing
# — "black screen for 2 seconds, then back to the menu" (Dan, 2026-09-08). setsid is busybox-common;
# if it is missing, the redirect + & still detaches the fds, which is the part that mattered.
spawn() { # spawn <binary> <args...>  — logs the command, never blocks the pak
	echo "-- $*" >> "$LOG"
	if command -v setsid >/dev/null 2>&1; then
		setsid "$@" </dev/null >>"$LOG" 2>&1 &
	else
		"$@" </dev/null >>"$LOG" 2>&1 &
	fi
	sleep 1
}

if listening; then
	say.elf "SSH is already running.

ssh root@$(ip_now)
(password: blank)"
	exit 0
fi

# Wifi first, exactly like Onion: no address, no daemon, and say so instead of failing quietly.
IP=$(ip_now)
if [ -z "$IP" ]; then
	confirm.elf --ok "No Network" "WiFi is not connected, so there
is nothing to listen on.

Turn WiFi on in Tools, reboot,
then run SSH again." "" "OKAY" ""
	exit 0
fi

# Key auth (Dan chose key + blank password, 2026-09-08). Install the card's public key so key auth
# works; -B still allows a blank-password root login as the fallback when /root is not writable —
# which is itself a suspected failure mode, so we do not depend on this cp succeeding.
for AK in "$SDCARD_PATH/authorized_keys" "$SSH_DIR/authorized_keys"; do
	[ -f "$AK" ] || continue
	mkdir -p /root/.ssh 2>/dev/null
	cp "$AK" /root/.ssh/authorized_keys 2>/dev/null \
		&& { chmod 700 /root/.ssh 2>/dev/null; chmod 600 /root/.ssh/authorized_keys 2>/dev/null; echo "authorized_keys installed from $AK" >> "$LOG"; } \
		|| echo "authorized_keys FAILED to install from $AK (/root not writable?)" >> "$LOG"
	break
done

echo "== ssh pak $(date 2>/dev/null)" >> "$LOG"

# A card host key so the device identity is stable across updates. Generate with whichever binary we
# have; the Onion build compiles in an SD path but accepts -r too.
if [ ! -f "$HK" ]; then
	if   [ -x "$ONION" ]; then "$ONION" -R >/dev/null 2>&1; "$BIN" dropbearkey -t ed25519 -f "$HK" >>"$LOG" 2>&1
	elif [ -x "$BIN" ];   then "$BIN" dropbearkey -t ed25519 -f "$HK" >>"$LOG" 2>&1
	fi
fi

# 1) Onion's proven binary FIRST. -B blank-password, -r our card key, -p 22. Detached via spawn().
[ -x "$ONION" ] && ! listening && spawn "$ONION" -B -r "$HK" -p 22

# 2) our own stock build.
[ -x "$BIN" ] && ! listening && spawn "$BIN" dropbear -B -r "$HK" -p 22

# 3) a dropbear already on PATH, Onion's exact -R -B invocation (its build makes its own key).
! listening && command -v dropbear >/dev/null 2>&1 && spawn dropbear -R -B

# 4) the console's own, at the paths stock firmwares use.
if ! listening; then
	for DB in /customer/app/dropbear /usr/sbin/dropbear /usr/bin/dropbear /bin/dropbear; do
		[ -x "$DB" ] || continue
		if [ -f "$HK" ]; then spawn "$DB" -B -r "$HK" -p 22; else spawn "$DB" -B -R -p 22; fi
		listening && break
	done
fi

if listening; then
	echo "RUNNING on $IP:22" >> "$LOG"
	say.elf "SSH is running.

ssh root@$IP
(password: blank)

Stays up until reboot."
else
	echo "FAILED: no daemon started" >> "$LOG"
	# Put the actual error ON SCREEN, not just in a file the user cannot open without ssh — the whole
	# point of this pak is that a silent failure cost an evening. Show the last log lines verbatim.
	TAIL=$(tail -6 "$LOG" 2>/dev/null)
	confirm.elf --ok "SSH Failed" "No daemon would start. Last log:

$TAIL" "" "OKAY" ""
fi
