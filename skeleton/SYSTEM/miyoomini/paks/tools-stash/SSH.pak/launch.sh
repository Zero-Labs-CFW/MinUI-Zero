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
# ROOT CAUSE, finally found on-device 2026-09-08 (via the passwordless telnet root shell this
# firmware leaves open): every dropbear here died with
#     libutil.so.1: cannot open shared object file: No such file or directory
# This device's glibc 2.28 was built WITHOUT libutil.so.1 (embedded builds strip it), and it is
# nowhere on the rootfs. BOTH our binary and Onion's need it (openpty/forkpty for the login PTY), so
# shipping Onion's binary alone would have failed identically — the earlier "same libs, so it can
# exec" note was exactly wrong: identical deps are not FINDABLE deps. Fix: we ship the matching
# armhf libutil.so.1 (pulled from our own toolchain, glibc 2.28, ABI-matched) and point the loader
# at it with LD_LIBRARY_PATH. This is what Onion does implicitly — its runtime.sh sets a long
# LD_LIBRARY_PATH across its own shipped lib dirs.
# Our own stock dropbearmulti is THE binary. We briefly also shipped Onion's prebuilt dropbear on
# the theory that ours "could not exec here" — but the real fault was the missing libutil.so.1
# (fixed below), not the binary, and Onion's build bakes in ONION-SPECIFIC paths (host keys and
# libs under /mnt/SDCARD/.tmp_update) that do not match our layout. With libutil supplied, our
# stock binary starts, listens, and accepts key auth from the standard /home/root/.ssh — proven on
# device 2026-09-08. So Onion's binary is gone; ours is the one true path.
BIN="$SYSTEM_PATH/bin/dropbearmulti"
FXLIB="$SYSTEM_PATH/lib"                 # holds libutil.so.1; prepended to the loader path below
export LD_LIBRARY_PATH="$FXLIB${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
SSH_DIR="$USERDATA_PATH/SSH"
HK="$SSH_DIR/dropbear_ed25519_host_key"
LOG="$LOGS_PATH/ssh-pak.txt"
mkdir -p "$SSH_DIR" "$LOGS_PATH" 2>/dev/null

# KEY AUTH ON A READ-ONLY ROOTFS. dropbear reads authorized_keys from the account's home
# (/home/root per /etc/passwd), but /home is a read-only squashfs and /home/root does not even
# exist — so the key cannot be dropped there, and blank-password login does NOT work either because
# root carries a real password hash. Mount a tmpfs over /home and recreate the home inside it, then
# install the card's public key. This is per-boot (tmpfs is RAM), which is fine: the pak re-does it
# every launch, and a dev card is the only place any of this runs.
setup_authkeys() {
	AK=""
	for c in "$SDCARD_PATH/authorized_keys" "$SSH_DIR/authorized_keys"; do [ -f "$c" ] && { AK="$c"; break; }; done
	[ -n "$AK" ] || { echo "no authorized_keys on card — key auth unavailable" >> "$LOG"; return 1; }
	# only mount if /home/root is not already a writable home (avoid stacking tmpfs on repeat runs)
	if ! { [ -d /home/root/.ssh ] && touch /home/root/.ssh/.wt 2>/dev/null && rm -f /home/root/.ssh/.wt; }; then
		mount -t tmpfs tmpfs /home 2>>"$LOG" || { echo "tmpfs /home failed — key auth unavailable" >> "$LOG"; return 1; }
	fi
	mkdir -p /home/root/.ssh 2>/dev/null
	cp "$AK" /home/root/.ssh/authorized_keys 2>/dev/null \
		&& { chmod 700 /home/root/.ssh; chmod 600 /home/root/.ssh/authorized_keys; echo "key auth ready from $AK" >> "$LOG"; return 0; }
	echo "could not install authorized_keys" >> "$LOG"; return 1
}

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

AUTH="key"; setup_authkeys || AUTH="none"

if listening; then
	if [ "$AUTH" = key ]; then say.elf "SSH is already running.

ssh root@$(ip_now)
(uses your SSH key)"
	else say.elf "SSH is already running.

ssh root@$(ip_now)
(no key installed — add
authorized_keys to the card)"
	fi
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

echo "== ssh pak $(date 2>/dev/null)" >> "$LOG"
# key auth was already set up above (setup_authkeys, before the listening check) via a tmpfs /home,
# because the real /home/root is read-only. Nothing to install here.

# A card host key so the device identity is stable across updates. Generate with whichever binary we
# have; the Onion build compiles in an SD path but accepts -r too.
if [ ! -f "$HK" ]; then
	if   [ -x "$ONION" ]; then "$ONION" -R >/dev/null 2>&1; "$BIN" dropbearkey -t ed25519 -f "$HK" >>"$LOG" 2>&1
	elif [ -x "$BIN" ];   then "$BIN" dropbearkey -t ed25519 -f "$HK" >>"$LOG" 2>&1
	fi
fi

# 1) our shipped stock binary. -B (root has a password, so blank login is off; key auth is the way
#    in — see setup_authkeys), -r the card host key, -p 22. Detached via spawn().
[ -x "$BIN" ] && ! listening && spawn "$BIN" dropbear -B -r "$HK" -p 22

# 2) the console's own, at the paths stock firmwares use.
if ! listening; then
	for DB in /customer/app/dropbear /usr/sbin/dropbear /usr/bin/dropbear /bin/dropbear; do
		[ -x "$DB" ] || continue
		if [ -f "$HK" ]; then spawn "$DB" -B -r "$HK" -p 22; else spawn "$DB" -B -R -p 22; fi
		listening && break
	done
fi

if listening; then
	echo "RUNNING on $IP:22 (auth=$AUTH)" >> "$LOG"
	if [ "$AUTH" = key ]; then say.elf "SSH is running.

ssh root@$IP
(uses your SSH key)

Stays up until reboot."
	else say.elf "SSH is running, but no SSH key
is installed and root has a
password, so you cannot log in.

Put authorized_keys on the card
root and run SSH again."
	fi
else
	echo "FAILED: no daemon started" >> "$LOG"
	# Put the actual error ON SCREEN, not just in a file the user cannot open without ssh — the whole
	# point of this pak is that a silent failure cost an evening. Show the last log lines verbatim.
	TAIL=$(tail -6 "$LOG" 2>/dev/null)
	confirm.elf --ok "SSH Failed" "No daemon would start. Last log:

$TAIL" "" "OKAY" ""
fi
