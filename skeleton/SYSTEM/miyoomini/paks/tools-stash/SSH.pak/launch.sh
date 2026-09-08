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

BIN="$SYSTEM_PATH/bin/dropbearmulti"
SSH_DIR="$USERDATA_PATH/SSH"
HK="$SSH_DIR/dropbear_ed25519_host_key"
LOG="$LOGS_PATH/ssh-pak.txt"
mkdir -p "$SSH_DIR" "$LOGS_PATH" 2>/dev/null

ip_now() { ip -4 addr show wlan0 2>/dev/null | sed -n 's/.*inet \([0-9.]*\).*/\1/p' | head -1; }
# Onion uses plain `pgrep dropbear`, which proves pgrep exists on this busybox. Keep a ps fallback
# anyway — busybox is a build-time menu, not a guarantee.
running() { pgrep dropbear >/dev/null 2>&1 || ps 2>/dev/null | grep -v grep | grep -q dropbear; }

if running; then
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

# Key auth if the card carries a public key; blank-password login stays available either way (-B).
for AK in "$SDCARD_PATH/authorized_keys" "$SSH_DIR/authorized_keys"; do
	[ -f "$AK" ] || continue
	mkdir -p /root/.ssh 2>/dev/null
	cp "$AK" /root/.ssh/authorized_keys 2>/dev/null \
		&& { chmod 700 /root/.ssh 2>/dev/null; chmod 600 /root/.ssh/authorized_keys 2>/dev/null; }
	break
done

# stderr is deliberately KEPT: dropbear's own message is the only thing that names a missing
# library or a bad key, and losing it is what made the boot block undiagnosable.
{
echo "== ssh pak $(date 2>/dev/null)"

# 1) our shipped binary, with the host key on the CARD so the device keeps one identity across
#    updates. Explicit -r avoids Onion's need for a writable /etc/dropbear: their build compiles in
#    an SD-card key path, ours is a stock 2022.83 that would default to a read-only /etc.
if [ -x "$BIN" ]; then
	[ -f "$HK" ] || "$BIN" dropbearkey -t ed25519 -f "$HK"
	echo "-- shipped dropbearmulti"
	"$BIN" dropbear -B -r "$HK" -p 22
	sleep 1
fi

# 2) a dropbear already on this firmware's PATH, started Onion's way verbatim.
if ! running; then
	echo "-- PATH dropbear (Onion's invocation)"
	dropbear -R -B
	sleep 1
fi

# 3) the console's own, at the paths stock firmwares use.
if ! running; then
	for DB in /customer/app/dropbear /usr/sbin/dropbear /usr/bin/dropbear /bin/dropbear; do
		[ -x "$DB" ] || continue
		echo "-- $DB"
		# -R when there is no card key yet: this branch is reached only if our own binary was absent,
		# so nothing has generated one, and -r on a missing file is a guaranteed "Failed loading keys".
		if [ -f "$HK" ]; then "$DB" -B -r "$HK" -p 22; else "$DB" -B -R -p 22; fi
		sleep 1
		running && break
	done
fi

running && echo "RUNNING on $IP:22" || echo "FAILED: no daemon started"
} >> "$LOG" 2>&1

if running; then
	say.elf "SSH is running.

ssh root@$IP
(password: blank)

Stays up until reboot."
else
	confirm.elf --ok "SSH Failed" "No daemon would start.

The exact error is on the card:
.userdata/miyoomini/logs/
ssh-pak.txt" "" "OKAY" ""
fi
