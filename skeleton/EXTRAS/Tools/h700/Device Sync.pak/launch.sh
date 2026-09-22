#!/bin/sh
# Device Sync -- "True Sync": ONE action. Both handhelds open Device Sync, both pick Sync, they pair
# over a self-hosted hotspot, ONE device shows exactly what is different, one confirm, and both end up
# in sync. No Send/Receive roles anywhere in the UI. No internet, no PC, no card swap.
#
# SAFETY, the whole model in one line: nothing is ever overwritten or removed without first copying it
# to a dated backup. Every write is backup -> staging -> verify -> atomic mv, journalled, so a power cut
# mid-apply resumes and any sync is restorable. A save that changed on BOTH devices keeps the NEWER
# copy automatically (by mtime); the older is backed up first, so a wrong guess under clock skew is
# recoverable from Restore (Dan chose this over a per-save prompt, 2026-09-19).
#
# ONE AUTHORITATIVE PLAN: the HOST computes the merge once from both manifests and serves the joiner its
# half. The joiner obeys that plan and never recomputes -- two devices merging independently can disagree
# under clock skew (Codex, 2026-09-18). The HOST also owns the single confirmation screen; the joiner
# just says "Reviewing on <host>" (Dan 2026-09-18: "One device to drive is totally fine").
#
# STATE MACHINE (explicit; a named status is on screen the instant each state begins, so never a blank):
#   ENTRY -> FIND (scan ~4 s: join an AP if one is up, else host; the LOWER token wins the both-at-once
#            race) -> COMPARE (manifests exchanged) -> REVIEW (host only) -> SYNC (joiner pulls and
#            applies, THEN host pulls and applies -- sequential, never interleaved) -> DONE
#   plus RESUME (an apply cut short by power loss) and RESTORE (put a backup back).
# Every error offers the action ("A Try again / B Back"), never a dead end.

HERE=$(dirname "$0"); NET="$HERE/sync-net.sh"; ENG="$HERE/sync-engine.sh"
net(){ sh "$NET" "$@"; }
eng(){ sh "$ENG" "$@"; }

SDCARD="${SDCARD_PATH:-/mnt/SDCARD}"; LOCAL="$SDCARD"
# The tool can be spawned with a STRIPPED environment on the Miyoo (observed 2026-09-19: PLATFORM=UNSET
# inside the running tool). That silently breaks the concurrency case below, the prefs dir, and worst,
# leaves the bundled hostapd's shipped libs (libnl-3/libssl/libcrypto in .system/<platform>/lib) off
# the loader path, so the hotspot can never start even though the same command works by hand with a
# full env. Derive everything from our OWN location instead of trusting the caller.
PAK_DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
# $0 is the pak path when MinUI runs us, but not when sourced (tests) -- so VALIDATE the derived
# name against a real .system dir and fall back to hardware signatures rather than trusting it.
if [ -z "${PLATFORM:-}" ] || [ ! -d "$SDCARD/.system/$PLATFORM" ]; then
	PLATFORM=$(basename "$(dirname "$PAK_DIR")")
	if [ ! -d "$SDCARD/.system/$PLATFORM" ]; then
		if [ -x /customer/app/axp_test ]; then PLATFORM=miyoomini
		elif [ -d "$SDCARD/.system/tg5040" ]; then PLATFORM=tg5040
		elif [ -d /mnt/mmc/.system/h700 ]; then PLATFORM=h700
		fi
	fi
fi
export PLATFORM
export SYSTEM_PATH="${SYSTEM_PATH:-$SDCARD/.system/$PLATFORM}"
export LOGS_PATH="${LOGS_PATH:-$SDCARD/.userdata/$PLATFORM/logs}"
export LD_LIBRARY_PATH="$SYSTEM_PATH/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}:/lib:/config/lib:/customer/lib"
# A fresh launch must never act on a PREVIOUS launch's saved home-WiFi config: a stale flag makes
# restore_wifi kill the live station supplicant on exit and drop the device off the network.
rm -f /tmp/dsync-home-conf /tmp/dsync-scan-nonblocking
export AP_IF=wlan1 STA_IF=wlan0 AP_IP=192.168.42.1 AP_PORT=8145
# The Brick's tg5040 has a TRUE second radio. The Miyoo (8188fu) shares ONE radio but its driver DOES
# hold an AP on wlan1 while wlan0 stays associated, on wlan0's channel -- VERIFIED on-device 2026-09-19
# (bundled hostapd AP-ENABLED, home WiFi kept, a Brick discovers the SSID). So both host CONCURRENTLY:
# no home-WiFi drop, no strand. The Anbernic RTL8821CS stays non-concurrent until proven. sync-net.sh
# reads DSYNC_CONCURRENT to pick the shape.
case "${PLATFORM:-}" in tg5040|miyoomini) export DSYNC_CONCURRENT=1 ;; *) if [ -x /customer/app/axp_test ]; then export DSYNC_CONCURRENT=1; else export DSYNC_CONCURRENT=0; fi ;; esac
PORT=8145; PSK=minuizerosync; SSID=MinUI-Sync
# Wire-protocol version, published with our prefs. Bump it whenever the manifest/plan/bundle shape or
# the handshake files change incompatibly; a peer on a different number is told to update instead of
# syncing by luck (two Zero builds, or a Zero and a NextUI port, can otherwise disagree silently).
DSYNC_PROTO=5
# Fork + build, INFORMATIONAL only (never a gate: a Zero 1.7 and a Zero 1.8, or a Zero and a NextUI port,
# on the same protocol number sync fine). They make the mismatch message say WHICH build to update.
DSYNC_FORK=zero
# version.txt line 1 is "v1.7.6 (20260920-15)" on a zip build and "MinUI Zero (dev-20260920)" on an h700 image
DSYNC_VER=$(head -1 "$SDCARD/.system/version.txt" 2>/dev/null | sed 's/^MinUI Zero //' | tr -d '()' | cut -d' ' -f1); [ -n "$DSYNC_VER" ] || DSYNC_VER=dev
SERVE=/tmp/dsync-serve; W=/tmp/dsync-work
TAB=$(printf '\t')

DS_DIR="$SDCARD/.userdata/$PLATFORM/devicesync"
BK_ROOT="$DS_DIR/backups"
STAGE="$DS_DIR/staging"        # downloads land ON THE CARD, never /tmp (RAM on a 1 GB device), and
                               # survive a reboot, which is what makes a dropped sync resumable
RES="$DS_DIR/resume"           # plan + backup pointer for an apply that was cut short
RES_PLAN="$RES/plan.txt"; RES_BK="$RES/backup"
LOGF="$SDCARD/.userdata/$PLATFORM/logs/devicesync.txt"
DEC="$W/decisions"             # REL \t a|b|skip -- conflict winners and per-item exclusions
mkdir -p "$(dirname "$LOGF")" "$DS_DIR" "$RES" "$STAGE" "$W" 2>/dev/null

# Per-device sync settings, remembered between runs. A category syncs only if BOTH devices have it on
# (the intersection rule), so each device decides for itself what it will share and accept. Defaults:
# only Saves on -- that is what "keep my saves up to date" means, and it is small and fast. Games OFF
# (a whole missing library is 24 GB / hours over WiFi) and Game Configs OFF (Dan 2026-09-19); opt either
# in per device.
PREFS="$DS_DIR/prefs"; PS=1; PG=0; PC=0; GSKIP=""
if [ -f "$PREFS" ]; then
	while IFS='=' read -r k v; do case "$k" in SAVES) PS=$v ;; GAMES) PG=$v ;; CONFIGS) PC=$v ;; GAMES_SKIP) GSKIP=$v ;; esac; done < "$PREFS"
fi
# normalize to EXACTLY 0 or 1: a damaged/legacy prefs file (empty or stray value) must not leave PS/PG/PC
# as "" -- that reads as off on screen but slips past the all-off guard and serves an ambiguous "S=" the
# peer treats as on (Codex, 2026-09-18). Anything that is not literal 1 becomes 0.
[ "$PS" = 1 ] || PS=0; [ "$PG" = 1 ] || PG=0; [ "$PC" = 1 ] || PC=0
save_prefs(){ printf 'SAVES=%s\nGAMES=%s\nCONFIGS=%s\nGAMES_SKIP=%s\n' "$PS" "$PG" "$PC" "$GSKIP" > "$PREFS.tmp" && mv "$PREFS.tmp" "$PREFS"; }
onoff(){ [ "$1" = 1 ] && printf On || printf Off; }

# human-friendly model name (Trimui Brick / Brick Pro / Smart Pro) -- how the fork already detects it
NAME="${TRIMUI_MODEL}"
[ -z "$NAME" ] && NAME=$(strings /usr/trimui/bin/MainUI 2>/dev/null | grep '^Trimui' | head -1)
[ -z "$NAME" ] && case "$PLATFORM" in
	miyoomini) if [ "$IS_FLIP" = true ]; then NAME="Miyoo Mini Flip"; elif [ "$IS_PLUS" = true ]; then NAME="Miyoo Mini Plus"; else NAME="Miyoo Mini"; fi ;;
	h700) case "$DEVICE" in rg35xx-plus|plus) NAME="RG35XX Plus" ;; rg35xx-h|h) NAME="RG35XX H" ;; *) NAME="Anbernic ${DEVICE:-H700}" ;; esac ;;   # the frontend exports DEVICE=plus|h
esac
[ -z "$NAME" ] && NAME="This device"

dbg(){ printf '%s [%s] %s\n' "$(date '+%H:%M:%S' 2>/dev/null)" "${ROLE:-?}" "$*" >> "$LOGF" 2>/dev/null; }
ts(){ date +%Y%m%d-%H%M%S 2>/dev/null || echo run; }

# ---- screens -------------------------------------------------------------------------------------
# status.elf is the no-button status screen (say.elf always draws a dismiss button and reads as a
# decision). ONE status process at a time, and during SYNC one process for the WHOLE transfer: many
# short-lived GFX tools exhausted the DE's contiguous memory and crashed the Plus (2026-09-18).
SMSG=/tmp/dsync-status.msg; SPROG=/tmp/dsync-status.prog; SPID=""; SCANCEL=0
smsg(){ printf '%s\n' "$1" > "$SMSG.tmp"; mv "$SMSG.tmp" "$SMSG"; }   # atomic: status.elf re-reads it every frame
# A plain status takes no buttons, so it must REPLACE a cancel-armed process rather than inherit it:
# reusing one would leave B able to kill the only screen up, in a state whose loop never polls stopped(),
# and the panel would sit black until the next screen change.
status(){ [ "$SCANCEL" = 1 ] && status_off
	smsg "$1"; : > "$SPROG"
	if [ -z "$SPID" ] || ! kill -0 "$SPID" 2>/dev/null; then status.elf "$SMSG" "$SPROG" >/dev/null 2>&1 & SPID=$!; fi
	return 0; }
# EVERY screen that waits arms B. A wait with no way out is the one thing a user cannot recover from
# without pulling the power, and pairing is mostly waiting (Dan, 2026-09-18: "There does not seem to be
# an easy way to cancel out of this process when it starts"). The caller MUST poll stopped() in its loop.
status_b(){ status_off; smsg "$1"; : > "$SPROG"; SCANCEL=1
	status.elf "$SMSG" "$SPROG" --cancel-b >/dev/null 2>&1 & SPID=$!; }
status_sync(){ status_b "$1"; }                                       # the long-lived one: B stops (resumable)
# ONE screen for the whole pairing sequence: a 3-dot progress row (Searching -> Connecting -> Connected)
# that advances in place, instead of a flurry of separate text screens (Dan, 2026-09-19). The message
# file holds the current step number, optionally followed by a caption line. B stops, like status_b.
STEPLABELS="Searching|Connecting|Connected"
status_steps(){ status_off; smsg "${1:-1}"; : > "$SPROG"; SCANCEL=1
	status.elf "$SMSG" --steps "$STEPLABELS" --cancel-b --cancel-label "Stop" --options-y >/dev/null 2>&1 & SPID=$!; }
step(){ smsg "$1"; }                                                  # advance the live stepper
stopped(){ [ -n "$SPID" ] && ! kill -0 "$SPID" 2>/dev/null || return 1
	wait "$SPID" 2>/dev/null; STOP_RC=$?; return 0; }   # status.elf exited: 1 = B (stop), 2 = Y (options)
# busybox sleep may have no fractional support; probe ONCE so the short waits below stay short instead
# of silently becoming 1 s each (a 20-step reap would be a 20 s black screen).
if sleep 0.1 2>/dev/null; then NAPN=20; nap(){ sleep 0.1; }; else NAPN=2; nap(){ sleep 1; }; fi
# REAP, do not just signal. status.elf handles SIGTERM by setting a flag and only releases the display in
# GFX_quit, so spawning the next screen immediately let the OLD process tear the display down AFTER the
# new one had painted -- a live screen showing black, and a second owner of a display that allows one
# (Codex, 2026-09-18). Wait for it to actually go.
status_off(){ if [ -n "$SPID" ]; then kill "$SPID" 2>/dev/null
		k=0; while kill -0 "$SPID" 2>/dev/null && [ "$k" -lt "$NAPN" ]; do nap; k=$((k+1)); done
		kill -0 "$SPID" 2>/dev/null && kill -9 "$SPID" 2>/dev/null
	fi
	SPID=""; SCANCEL=0; killall status.elf 2>/dev/null; rm -f "$SMSG" "$SPROG"; return 0; }
# every interactive screen takes the display, so the status must be down first -- these wrap that up
tell(){ status_off; say.elf "$1"; }
ask(){ status_off; confirm.elf "$@"; }
menu(){ status_off; settings.elf "$@"; }
# an error is never a dead end: it offers the action. 0 = do it again, 1 = back out.
oops(){ status_off; confirm.elf "$1" "${2:-TRY AGAIN}" "BACK"; }
ap_alive(){ pidof hostapd >/dev/null 2>&1 && return 0
	for p in $(pidof wpa_supplicant 2>/dev/null); do
		case "$(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null)" in *"$AP_IF"*) return 0 ;; esac
	done
	return 1; }

# Never sleep mid-transfer. STAY_AWAKE_PATH is honored by PWR_preventAutosleep on every platform; left
# alone if dev mode already set it.
if [ "${DSYNC_LIB:-0}" = 1 ]; then DS_STAY=0
elif [ -f /tmp/stay_awake ]; then DS_STAY=0; else touch /tmp/stay_awake; DS_STAY=1; fi
# h700 (muOS guest): muOS blanks the panel after `idle_display` seconds of no BUTTON input (mux/idle.sh),
# and a sync runs input-idle for minutes, so the Plus went blank mid-transfer (root-caused 2026-09-18).
# Our /tmp/stay_awake only governs OUR autosleep; muOS's screensaver is separate. muOS keeps the screen on
# while its own idle_inhibit flag is 1 -- idle.sh re-derives that every 5s from a process watch list we are
# not on, so hold it at 1 ourselves (re-assert faster than the 5s loop). Nothing to restore: idle.sh puts
# it back. No-op off h700 (the file is absent on TrimUI/Miyoo).
MUOS_IDLE=/opt/muos/config/system/idle_inhibit; MUOS_INHIBIT_PID=""
if [ -f "$MUOS_IDLE" ] && [ "${DSYNC_LIB:-0}" != 1 ]; then ( while :; do printf 1 > "$MUOS_IDLE" 2>/dev/null; sleep 3; done ) & MUOS_INHIBIT_PID=$!; fi
stay_off(){ [ "$DS_STAY" = 1 ] && rm -f /tmp/stay_awake; [ -n "$MUOS_INHIBIT_PID" ] && kill "$MUOS_INHIBIT_PID" 2>/dev/null; return 0; }

# ============================== pure logic (no UI, no radio, no files on the card) ==================
# Everything between these markers is exercised by .notes/-side flow-logic-test.sh, which copies this
# block out and runs it on the host. Keep it free of status.elf/net/eng calls.
# >>> pure logic

fmt_kb(){ if [ "$1" -ge 1048576 ]; then printf '%s.%s GB' "$(( $1 / 1048576 ))" "$(( ($1 % 1048576) * 10 / 1048576 ))"; elif [ "$1" -ge 1024 ]; then printf '%s MB' "$(( $1 / 1024 ))"; else printf '%s KB' "$1"; fi; }
# <KB left> [KB/s measured]: the rate comes from the last ~60 s of the transfer (prog keeps samples); the old
# fixed 1.2 MB/s said "6 h" for a copy that was moving at 3.2 MB/s (2026-09-22). Until 5 s of samples
# exist it falls back to that constant; a hint, never a promise.
eta(){ r=${2:-0}; [ "$r" -gt 0 ] 2>/dev/null || r=1200
	if [ "${1:-0}" -le "$r" ]; then printf 'moments'; return 0; fi
	s=$(( $1 / r ))
	if [ "$s" -lt 90 ]; then printf 'about a minute'; elif [ "$s" -lt 5400 ]; then printf 'about %s min' "$(( (s + 59) / 60 ))"; else printf 'about %s h' "$(( (s + 1799) / 3600 ))"; fi; }
# engine class -> the word the user sees, and the order the categories are listed in
cat_label(){ case "$1" in
	save) printf 'Saves' ;; rom) printf 'Games' ;; config) printf 'Game settings' ;;
	recent) printf 'Recently played' ;; favorite) printf 'Favorites' ;; collection) printf 'Collections' ;; map) printf 'Button maps' ;;
	*) printf 'Other files' ;; esac; }
# --- the whole simple flow: merge two snapshots, keep the newer of any clash, one confirm ----------
# newest-wins decisions for every conflict (a save changed on BOTH). a = this device (host/A) wins,
# b = the other (joiner/B); a tie keeps A. Games are never conflicts (matched by name -> skip), so this
# only ever decides saves and states, and the loser is ALWAYS backed up before it is replaced, so a
# wrong guess under clock skew is recoverable from Restore. mtime is field 3 of each manifest.
auto_resolve(){ # <my.mf> <peer.mf> <merge> -> decisions (REL \t a|b) on stdout
	awk -F"$TAB" -v OFS="$TAB" -v off="${CLK_OFF:-0}" -v pboot="${PEER_BOOT:-0}" -v aboot="${MY_BOOT:-0}" '
		FILENAME==ARGV[1] { amt[$1]=$3; next }
		FILENAME==ARGV[2] { bmt[$1]=$3; next }
		FILENAME==ARGV[3] && $1=="conflict" { rel=$4; bm = ((pboot > 0 && (bmt[rel]+0) < pboot) || (aboot > 0 && (amt[rel]+0) < aboot)) ? bmt[rel]+0 : bmt[rel]+0+off; print rel, ((amt[rel]+0) >= bm ? "a" : "b") }
	' "$1" "$2" "$3"; }

# Two devices of the same model report the same name, and the review screen names both sides, so make
# them tellable apart rather than showing "Brick" twice (the plan's "a code only if names collide").
# Two lines out: this device first, the peer second.
disambiguate(){ if [ "$1" = "$2" ]; then printf '%s (this one)\n%s (other)\n' "$1" "$2"; else printf '%s\n%s\n' "$1" "$2"; fi; }

# The Done sentence is rendered by WHOEVER READS IT, from three counts. The host used to compose the
# finished line and serve it verbatim -- but the labels above are viewer-relative, so on two devices of
# the same model the joiner's screen read "(this one) received 8" about the HOST's 8 (2026-09-18 review).
done_text(){ # <A received> <B received> <skipped> <A name> <B name>
	if [ "${3:-0}" -gt 0 ]; then t="$3 game(s) in skipped systems."; else t="Both devices are up to date."; fi
	printf 'Synced!\n\n%s received %s.\n%s received %s.\n\n%s' "$4" "$1" "$5" "$2" "$t"; }

# Free space a device must have to RECEIVE <kb>: the transfer once (apply MOVES staged files into place,
# same card), a 10% margin for backups of replaced saves, and one bundle chunk (200 MB cap) of slack
# for the archive that sits beside the extracted files. The old 2x budget refused a 25 GB library on a
# 29 GB card (2026-09-21).
need_kb(){ [ "${1:-0}" -gt 0 ] || { printf 0; return 0; }
	h=$1; [ "$h" -gt 204800 ] && h=204800
	printf '%s' "$(( $1 + $1 / 10 + h + 10240 ))"; }

# A 4-hex token keeps the SSID short and makes the election a plain string compare. The first half comes
# from the radio MAC (different by construction on two devices), the second is rolled fresh each run so
# that the 1-in-256 chance of a matching pair cannot deadlock the same two devices forever.
mk_token(){ m=$(printf '%s' "$1" | tr -d ':' | tr 'A-Z' 'a-z' | tail -c 2)
	case "$m" in [0-9a-f][0-9a-f]) : ;; *) m=$(awk -v s="$2" 'BEGIN{srand(s%2147483647); printf "%02x", rand()*256}') ;; esac
	printf '%s%s' "$m" "$(awk -v s="$2" 'BEGIN{srand((s+7)%2147483647); printf "%02x", rand()*256}')"; }
# the lowest-token MinUI-Sync SSID in a scan, ignoring our own (the prefix is fixed, so plain sort order
# IS token order). Empty means nobody is hosting.
peer_ssid(){ printf '%s\n' "$2" | grep '^MinUI-Sync-' | grep -v "^$1\$" | sort -u | head -1; }
# hosting and we spot a LOWER token: drop our AP and join theirs. Deterministic tiebreak for the
# both-tapped-Sync-at-once race; prints the SSID to yield to, or nothing.
yield_to(){ p=$(peer_ssid "$1" "$2"); [ -n "$p" ] || return 0
	[ "$(printf '%s\n%s\n' "$1" "$p" | sort | head -1)" = "$p" ] && printf '%s' "$p"; return 0; }

# the joined client's address, read from ARP rather than assumed: udhcpd hands out .10-.20 and a second
# run can land on .11, which the old hardcoded .10 would have talked past. Incomplete entries ignored.
arp_peer_ip(){ printf '%s\n' "$1" | awk -v me="$2" '$1 ~ /^192\.168\.42\./ && $1 != me && $4 != "00:00:00:00:00:00" {print $1; exit}'; }

# the authoritative plan for ONE direction: ACTION \t CLASS \t SIZE \t REL \t HASH \t MTIME, ACTION
# always "take". HASH lets the engine's resume-check verify a staged file byte-for-byte; MTIME carries
# the source file's time, because wget does not preserve it and without it every file we just downloaded
# looks "newer" than local on the NEXT sync. Both come from whichever manifest the file is travelling
# FROM. Excluded categories and per-item "skip" decisions drop out here, and a conflict only travels once
# the user has named a winner -- an undecided conflict moves nothing, in either direction.
build_plan(){ # <merge> <decisions> <skipped classes csv> <to-a|to-b> <A manifest> <B manifest>
	awk -F"$TAB" -v OFS="$TAB" -v want="$4" -v skip="$3" '
		function excluded(c,   n,i,p) { n=split(skip,p,","); for(i=1;i<=n;i++) if (p[i]==c) return 1; return 0 }
		FILENAME==ARGV[1] { dec[$1]=$2; next }
		FILENAME==ARGV[2] { asz[$1]=$2; amt[$1]=$3; ah[$1]=$5; next }
		FILENAME==ARGV[3] { bsz[$1]=$2; bmt[$1]=$3; bh[$1]=$5; next }
		{ d=$1; c=$2; s=$3; rel=$4
		  if (d=="skip") next
		  if (excluded(c)) next
		  if (dec[rel]=="skip") next
		  if (d=="conflict") {
			if (dec[rel]=="a")      { d="to-b"; s=asz[rel] }   # A wins -> B takes the A copy
			else if (dec[rel]=="b") { d="to-a"; s=bsz[rel] }
			else next                                          # undecided: nothing moves
		  }
		  if (d != want) next
		  if (d=="to-b") print "take", c, s+0, rel, (rel in ah ? ah[rel] : "-"), (rel in amt ? amt[rel] : 0)
		  else           print "take", c, s+0, rel, (rel in bh ? bh[rel] : "-"), (rel in bmt ? bmt[rel] : 0) }
	' "$2" "$5" "$6" "$1"; }

plan_count(){ awk 'END{print NR+0}' "$1"; }
plan_kb(){ awk -F"$TAB" '{b+=$3} END{printf "%d", int((b+1023)/1024)}' "$1"; }
# what the user chose NOT to copy, for the Done screen's honesty ("3 skipped" vs "up to date")
skipped_count(){ awk -F"$TAB" '$1!="skip"{t++} END{print t+0}' "$1"; }

# Games are chosen per SYSTEM on the host (the device you hold), from the systems the merge would move,
# and remembered by tag as a SKIP list, so a new system syncs by default ("all minus PS1", Dan 2026-09-21).
# A skipped system moves in neither direction. The tag is the last parenthesised group of the console
# folder ("6) PlayStation (PS)" -> PS), the same identity MinUI itself uses, so it survives renamed folders.
sys_rows(){ # <merge> [sysmap] -> TAG \t NAME \t games \t KB, one line per system with a game to move
	awk -F"$TAB" -v OFS="$TAB" 'FILENAME==ARGV[1] { if ($1!="") folder[$1]=$2; next }
		$1!="skip" && $2=="rom" && $4 ~ /^Roms\// {
		f=$4; sub(/^Roms\//,"",f); sub(/\/.*/,"",f)
		tag=f; if (match(f,/\([^()]*\)[^()]*$/)) { tag=substr(f,RSTART+1); sub(/\).*/,"",tag) }
		if (f in folder) f=folder[f]   # a tag path (Roms/PS/...) shows the folder name on this card
		name=f; sub(/^[0-9]+\) /,"",name); sub(/ *\([^()]*\)[^()]*$/,"",name)
		# a GAME is one top-level entry in the system folder: a file, or a folder (a port with hundreds of
		# files, a CD game with .bin + .cue). Counting files said "Ports (329 games)" for three ports.
		g=$4; sub(/^Roms\/[^\/]*\//,"",g); sub(/\/.*/,"",g)
		if (!((tag SUBSEP g) in seen)) { seen[tag SUBSEP g]=1; n[tag]++ }
		kb[tag]+=$3; nm[tag]=name }
		END { for (t in n) print t, nm[t], n[t], int(kb[t]/1024) }' "${2:-/dev/null}" "$1" | sort -t"$TAB" -k2,2; }
drop_systems(){ # <merge> <skip csv> -> the merge without the skipped systems (either direction)
	awk -F"$TAB" -v skip=",$2," '$2=="rom" && $4 ~ /^Roms\// {
		f=$4; sub(/^Roms\//,"",f); sub(/\/.*/,"",f)
		tag=f; if (match(f,/\([^()]*\)[^()]*$/)) { tag=substr(f,RSTART+1); sub(/\).*/,"",tag) }
		if (index(skip, "," tag ",")) next }
		{ print }' "$1"; }
in_csv(){ case ",$2," in *",$1,"*) return 0 ;; esac; return 1; }

# Backups: one row per NAME+TYPE of a snapshot (a game's save and its state collapse into one row, like the
# sync list), so a row can be put back on its own. Class from the path, the same rules as the engine.
restore_rows(){ # <ops.log> -> ORD \t NAME \t TYPE \t REL (one line per rel; rows are deduped by NAME+TYPE by the caller)
	awk -F"$TAB" -v OFS="$TAB" '{ rel=$3; if (rel=="") next; n=rel; sub(/.*\//,"",n)
		if (rel ~ /favorites\.txt$/)        { name="Favorites"; type="Favorite"; ord=4 }
		else if (rel ~ /^Collections\//)     { sub(/\.[^.]*$/,"",n); name=n; type="Collection"; ord=6 }
		else if (rel ~ /^Roms\//)            { sub(/\.[^.]*$/,"",n); name=n; type="Game"; ord=2 }
		else if (rel ~ /\.cfg$/)             { sub(/\.[^.]*$/,"",n); name=n; type="Settings"; ord=3 }
		else if (rel ~ /^Saves\// || rel ~ /\.st[0-9](\.[^.]*)?$/) { sub(/\.[^.]*$/,"",n); sub(/\.st[0-9]$/,"",n); if (rel ~ /^Saves\//) sub(/\.[^.]*$/,"",n); name=n; type="Save"; ord=1 }
		else                                 { sub(/\.[^.]*$/,"",n); name=n; type="File"; ord=7 }
		print ord, name, type, rel }' "$1" | sort -t"$TAB" -k1,1n -k2,2
}

# <<< pure logic
# ===================================================================================================

# Never use wc -c for a size: busybox wc READS the file, which on a card of PS1 images meant reading
# gigabytes to size them. Field 5 of ls -ln is the byte count on busybox, GNU and BSD alike.
file_bytes(){ [ -e "$1" ] || { printf 0; return 0; }; ls -lnL "$1" 2>/dev/null | { read -r _p _l _u _g s _r; printf '%s' "${s:-0}"; }; }

# is the staged copy complete and correct? <rel> <size> <hash> ("-" = a ROM: size only, never hash GBs)
staged_ok(){ [ -f "$STAGE/$1" ] || return 1
	[ "$(file_bytes "$STAGE/$1")" = "$2" ] || return 1
	[ "$3" = "-" ] && return 0
	[ "$(md5sum "$STAGE/$1" 2>/dev/null | cut -d' ' -f1)" = "$3" ]; }

# The sync scope: user content, never firmware. Whole trees by name so build-export symlinks them
# instead of walking every game (the per-game walk cost minutes on a 765-game card, 2026-09-05).
# build-export silently skips anything that is not there.
# EVERYTHING is exported; the toggles decide what each device TAKES, per direction (Dan, 2026-09-21:
# Games on the Plus and off on the Pro must still bring games to the Plus). The old both-on rule needed
# both devices to opt in, which nobody expected. Walking the library is one batched find/stat pass,
# seconds even for a 25 GB card, so exporting it unconditionally costs little.
#   Saves    -> Saves/, save states + thumbs (.userdata/shared/<tag>-<core>/), collections, favorites
#   Games    -> Roms/ and Bios/ (existence by name; never overwritten, never deleted)
#   Configs  -> per-game / per-console .cfg dirs (.userdata/$PLATFORM/<tag>-<core>/)
scope_list(){
	printf '%s\n' Saves Collections ".userdata/shared/.minui/favorites.txt"   # Recently Played stays per device
	for d in "$LOCAL"/.userdata/shared/*-*/; do [ -d "$d" ] || continue; d=${d%/}; printf '%s\n' "${d#"$LOCAL"/}"; done
	printf '%s\n' Roms Bios   # a BIOS rides with Games
	if :; then
		# a real config dir has at least one .cfg -- tells it apart from app state that also has a hyphen
		for d in "$LOCAL"/.userdata/$PLATFORM/*-*/; do
			[ -d "$d" ] || continue; dn=${d%/}; dn=${dn##*/}
			case "$dn" in nextui-pak-store) continue ;; esac
			ls "$d"*.cfg >/dev/null 2>&1 || continue
			d=${d%/}; printf '%s\n' "${d#"$LOCAL"/}"
		done
	fi
	return 0; }
# the classes a device does NOT take, from ITS OWN toggles: <S> <G> <C> -> csv (per direction)
skip_classes(){ sc=""
	[ "$1" = 1 ] || sc="save,favorite,collection"
	[ "$2" = 1 ] || sc="${sc:+$sc,}rom"
	[ "$3" = 1 ] || sc="${sc:+$sc,}config,map"
	printf '%s' "$sc"; }
# breakdown of what will actually transfer, counted from the built plans (post-skip). class is field 2.
plan_break(){ out=""
	for c in save rom config recent favorite collection map other; do
		k=$(awk -F"$TAB" -v cl="$c" '$2==cl{t++} END{print t+0}' "$1" "$2" 2>/dev/null)
		[ "${k:-0}" -gt 0 ] && out="${out:+$out, }$k $(cat_label "$c")"
	done
	printf '%s' "$out"; }

plan_names(){ # <plan.me> <plan.peer> -> deduped "Name<TAB>Type", most useful first (what the user reviews)
  awk -F"$TAB" -v OFS="$TAB" '
    { rel=$4; cls=$2; n=rel; sub(/.*\//,"",n)
      if (rel ~ /favorites\.txt$/)      { name="Favorites";       type="Favorite"; ord=4 }
      else {
        sub(/\.[^.]*$/,"",n); sub(/\.st[0-9]$/,"",n); if (rel ~ /^Saves\//) sub(/\.[^.]*$/,"",n); name=n   # Zelda.gbc.sav and Zelda.st0 are one row
        if (cls=="save")            { type="Save";       ord=1 }
        else if (cls=="rom")        { type="Game";       ord=2 }
        else if (cls=="config")     { type="Settings";   ord=3 }
        else if (cls=="collection") { type="Collection"; ord=6 }
        else                        { type="File";       ord=7 }
      }
      if (name=="") next
      k=name SUBSEP type
      if (!(k in seen)) { seen[k]=1; print ord, name, type }
    }
  ' "$1" "$2" | sort -t"$TAB" -k1,1n -k2,2 | cut -f2-
}

# EVERY http call goes through here. busybox wget's -T is a COMPILE-TIME feature
# (FEATURE_WGET_TIMEOUT) and the Brick's busybox 1.27.2 is built WITHOUT it: -T is absent from its usage
# string, and passing it does not error -- it SEGFAULTS, rc 139, before a single byte leaves the device.
# Isolated on a Brick Pro 2026-09-18: `wget -O F URL` rc=0, `wget -T 8 -O F URL` rc=139. Every HTTP call
# in this file carried -T, so manifests, status polls and file downloads had ALL been crashing since the
# day this pak shipped. That is the whole reason the host's httpd log was always empty and the two
# devices always ended up "losing" each other -- there was never a network fault at all.
# There is no `timeout` applet either, so bound it by hand. Verified on-device: correct status for
# success, 404 and refused; exact stdout capture with no job-control text; a 189 KB body byte-identical;
# 20/20 calls clean; a dead peer returns in 1 s and a black hole is cut off at the deadline.
# rc = wget's own status, or 1 if it overstayed.
hget(){ secs=$1; shift
	wget -q "$@" 2>/dev/null & wpid=$!
	# Poll at the FINEST granularity this busybox has, never in whole seconds. `kill -0` on a child that
	# has just been forked always succeeds, and a child that has already finished stays a zombie until
	# `wait` reaps it -- so a `sleep 1` loop puts a hard ONE SECOND FLOOR under every single HTTP call.
	# fetch_file sends every file under 4 MiB through here, which on a card with hundreds of saves,
	# states and per-game configs is minutes of pure sleeping on a transfer whose bytes take seconds.
	# Measured at exactly 1.00 s per fetch against a local httpd on busybox 1.27.2 (sweep, 2026-09-18).
	# NAPN is ticks-per-TWO-seconds from the single sleep probe above (20 fractional, 2 otherwise), so
	# ticks-per-second is half of it and `nap` is one tick.
	lim=$(( secs * (NAPN / 2) )); [ "$lim" -lt 1 ] && lim=1
	k=0
	while kill -0 "$wpid" 2>/dev/null && [ "$k" -lt "$lim" ]; do nap; k=$((k+1)); done
	if kill -0 "$wpid" 2>/dev/null; then kill -9 "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null; return 1; fi
	wait "$wpid"; }
# hget that honours B: for the long bundle pulls, where fetch_file's rule (never a download the user
# cannot stop) was bypassed and a 700 MB bundle ran to its deadline behind a blank panel (QA 2026-09-20)
hget_c(){ # <secs> <dst> <url>; 0 done, 1 deadline or stalled, 3 stopped by the user
	wget -q -O "$2" "$3" 2>/dev/null & wpid=$!
	k=0; last=-1; stall=0
	while kill -0 "$wpid" 2>/dev/null && [ "$k" -lt "$1" ]; do
		stopped && { kill -9 "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null; return 3; }
		sleep 1; k=$((k+1))
		sz=$(file_bytes "$2"); PART_KB=$((sz / 1024)); [ -n "${PLABEL:-}" ] && prog "$PLABEL"   # the chunk growing = visible progress
		# a dead connection (a re-join after a loss left one) must fail over to the per-file path, not
		# wait out a deadline that scales with the plan (5 h for 1 GB, 2026-09-22)
		if [ "$sz" = "$last" ]; then stall=$((stall+1)); else stall=0; last=$sz; fi
		[ "$stall" -ge 30 ] && { kill -9 "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null; return 1; }
	done
	if kill -0 "$wpid" 2>/dev/null; then kill -9 "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null; return 1; fi
	wait "$wpid"; }

# poll for a file the peer may still be writing (it builds its export while we build ours)
fetch(){ i=0; while [ "$i" -lt "$3" ]; do
		hget 8 -O "$2" "$1" && return 0
		rm -f "$2"; sleep 2; i=$((i+2)); done
	return 1; }
# The same poll, but it also watches the pad and the peer, so a wait is never a frozen screen: a plain
# fetch of the peer manifest sat on one unchanging line for a full four minutes when the other device was
# not serving, with B doing nothing (Dan, 2026-09-18: "It has been at least 2 minutes"). Requires a
# status_b screen to be up. <url> <dst> <maxsec> <peer-ip> -> 0 got it, 1 gave up, 2 user pressed B.
now(){ v=$(date +%s 2>/dev/null); case "$v" in ''|*[!0-9]*) printf 0 ;; *) printf '%s' "$v" ;; esac; }
fetch_live(){ st=$(now); dl=0; [ "$st" != 0 ] && dl=$((st + $3))
	i=0; miss=0
	while :; do
		# a real deadline, not a tick count: one pass costs up to 8 s of wget plus 2 s of ping plus the
		# 2 s sleep, so counting ticks made a nominal 240 s wait run for twenty minutes against a peer
		# that answered ICMP but not HTTP (Codex, 2026-09-18). Ticks remain the fallback if date is odd.
		if [ "$dl" != 0 ]; then [ "$(now)" -lt "$dl" ] || break; else [ "$i" -lt "$3" ] || break; fi
		hget 8 -O "$2" "$1" && return 0
		rm -f "$2"
		stopped && return 2
		if ping -c1 -W2 "$4" >/dev/null 2>&1; then miss=0; else miss=$((miss+1)); fi
		[ "$miss" -ge 5 ] && return 1
		sleep 2; i=$((i+2))
	done
	return 1; }
# The joiner's address, for a host that has an association but no ARP entry yet. udhcpd hands out
# .10 through .20, so probe the pool rather than assuming .10: a ping both finds the right one AND
# populates ARP. Prints nothing if nobody answers.
peer_probe(){ k=10
	while [ "$k" -le 20 ]; do
		ping -c1 -W1 "192.168.42.$k" >/dev/null 2>&1 && { printf '192.168.42.%s' "$k"; return 0; }
		k=$((k+1))
	done
	return 1; }

# The radio is off by default on Zero (boot.sh) and a scan needs the station interface up. join()
# powers itself on; this is only for the scan that precedes it.
radio_up(){ command -v rfkill >/dev/null 2>&1 && rfkill unblock wifi 2>/dev/null   # Zero blocks the radio at non-devmode boot
	if [ ! -e "/sys/class/net/$STA_IF" ]; then
		[ -x /customer/app/axp_test ] && /customer/app/axp_test wifion >/dev/null 2>&1
		# a real power-on re-enumerates the USB radio; give the interfaces time to appear
		i=0; while [ ! -e "/sys/class/net/$STA_IF" ] && [ "$i" -lt 15 ]; do sleep 1; i=$((i+1)); done
	fi
	ifconfig "$STA_IF" up 2>/dev/null; return 0; }

HOMEIP=$(ip -4 addr show "$STA_IF" 2>/dev/null | sed -n 's/.*inet \([0-9.]*\).*/\1/p' | head -1)
case "$HOMEIP" in 192.168.42.*|"") HAD_WIFI=0 ;; *) HAD_WIFI=1 ;; esac
# no lease yet is not "no WiFi": a supplicant or dhcpcd already running means the home network was
# configured and merely associating, and wifi-off at teardown would have killed it (QA 2026-09-20)
pidof wpa_supplicant >/dev/null 2>&1 && HAD_WIFI=1; pidof dhcpcd >/dev/null 2>&1 && HAD_WIFI=1
TORN=0
teardown(){
	[ "$TORN" = 1 ] && return 0
	TORN=1
	dbg "teardown: begin (role=${ROLE:-?} had_wifi=$HAD_WIFI)"
	status_off
	net stop-serve >/dev/null 2>&1
	net ap-down >/dev/null 2>&1
	# restore-wifi is a no-op unless join/ap-up actually saved the home config, so a run that never
	# touched the radio leaves it exactly as it was (knocking a Brick off its network, 2026-09-05).
	# Reconnecting takes 5-30 s (association poll + lease): SHOW it instead of a black panel, and never
	# hold the menu hostage: after 40 s the menu comes back while the reconnect finishes on its own
	# (the Plus sat on a black screen for good here, 2026-09-21).
	if [ "$HAD_WIFI" = 1 ]; then
		rm -f "$BUSY"   # the force-quit guard restores only while BUSY names us: not twice
		status "Reconnecting WiFi..."
		( net restore-wifi >/dev/null 2>&1 ) & rp=$!
		i=0; while kill -0 "$rp" 2>/dev/null && [ "$i" -lt 40 ]; do sleep 1; i=$((i+1)); done
		[ "$i" -ge 40 ] && dbg "teardown: restore-wifi still running after 40 s, menu returns"
		status_off
	else net wifi-off >/dev/null 2>&1; fi
	rm -rf "$SERVE" "$DS_DIR/out"; rm -f "$BUSY"
	stay_off; dbg "teardown: done"; }
# Dev cards run a net-keeper that bounces wlan0 when the gateway is unreachable for 60 s; our join
# removes the gateway on purpose. This flag tells it to stand down until teardown clears it.
BUSY=/tmp/dsync-radio-busy
if [ "${DSYNC_LIB:-0}" != 1 ]; then
printf '%s\n' "$$" > "$BUSY"
# A signal trap RETURNS into the script unless it exits, so `trap teardown TERM` used to tear the radio
# down and then carry on running the state machine with no radio and no marker (Codex, 2026-09-18).
# Each signal exits; teardown itself is idempotent so the EXIT trap that follows is a no-op.
trap 'teardown' EXIT
trap 'teardown; exit 130' INT
trap 'teardown; exit 143' TERM HUP
# ...and insurance for the kill a trap CANNOT catch. A force-quit (MENU/power) SIGKILLs the pak, teardown
# never runs, and the device is left broadcasting MinUI-Sync-xxxx with home WiFi still down -- observed
# after the first real run (2026-09-18). A detached watchdog waits for this pid to go and cleans up if
# teardown did not (teardown removes the busy flag, so a clean exit makes this a no-op).
# The marker carries OUR pid, and the guard only acts if it still reads that: a bare flag file is
# global, so a run that started inside the two-second poll window would have had its radio, its httpd
# and its screen torn down by the PREVIOUS run's watchdog (Codex, 2026-09-18).
DS_GUARD="while kill -0 $$ 2>/dev/null; do sleep 2; done
[ \"\$(cat $BUSY 2>/dev/null)\" = '$$' ] || exit 0
sh '$NET' stop-serve >/dev/null 2>&1
sh '$NET' ap-down >/dev/null 2>&1"
if [ "$HAD_WIFI" = 1 ]; then DS_GUARD="$DS_GUARD
sh '$NET' restore-wifi >/dev/null 2>&1"
else DS_GUARD="$DS_GUARD
sh '$NET' wifi-off >/dev/null 2>&1"; fi
[ -n "$MUOS_INHIBIT_PID" ] && DS_GUARD="$DS_GUARD
kill $MUOS_INHIBIT_PID 2>/dev/null"
[ "$DS_STAY" = 1 ] && DS_GUARD="$DS_GUARD
rm -f /tmp/stay_awake"
DS_GUARD="$DS_GUARD
killall status.elf 2>/dev/null
for pp in $(cat /tmp/dsync-muos-monitor 2>/dev/null); do kill -CONT $pp 2>/dev/null; done; rm -f /tmp/dsync-muos-monitor
rm -rf $SERVE $DS_DIR/out; rm -f $BUSY"
# setsid puts it in its own session so a group-wide kill does not take the cleanup with it
if command -v setsid >/dev/null 2>&1; then setsid sh -c "$DS_GUARD" >/dev/null 2>&1 &
else sh -c "$DS_GUARD" >/dev/null 2>&1 & fi
fi   # end: skipped in library mode

# The hotspot name is chosen ONCE PER RUN, never per pass. Re-deriving it on a retry renamed the AP out
# from under a peer that had already associated to the old name, which is exactly how the first real run
# failed: the host gave up, re-elected as MinUI-Sync-91ff, and the Brick Pro sat holding a lease from
# MinUI-Sync-9160 (2026-09-18).
TOKEN=$(mk_token "$(cat "/sys/class/net/$STA_IF/address" 2>/dev/null)" "$$$(date +%s 2>/dev/null)")
# A device with no scanner (no iw: the Miyoo) can never see a rival, so it always elects host and can
# never join. Give it the LOWEST possible token so every scanning peer yields to it instead of both
# hosting for ten minutes when the Brick happened to draw the lower number (QA 2026-09-20).
command -v iw >/dev/null 2>&1 || TOKEN=0000
# The hotspot name CARRIES the device name, so a joiner knows WHO it found the instant a scan sees the
# SSID ("Found Brick Pro" on the stepper), not seconds later after connecting. The token stays right
# after the prefix so peer_ssid/yield_to still order by token. 32-char SSID: prefix+token is 16, so
# the name is cut to 15 and reduced to letters, digits and spaces.
NSHORT=$(printf '%s' "$NAME" | tr -c 'A-Za-z0-9 ' ' ' | tr -s ' ' | cut -c1-16 | sed 's/ *$//')   # 11 + 4 + 1 + 16 = the 32-byte SSID; "Trimui Brick Pro" is 16
MYSSID="$SSID-$TOKEN${NSHORT:+-$NSHORT}"
dbg "==== launch name=$NAME had_wifi=$HAD_WIFI ssid=$MYSSID ===="

# ---- the transfer ---------------------------------------------------------------------------------
# PART_KB = bytes of the file in flight (fetch_file updates it every second), so the bar and the ETA move
# inside a 700 MB image instead of freezing until it lands. RATE_F holds (time, KB) samples for eta.
prog(){ PLABEL="$1"; shown=$(( ${DONE_KB:-0} + ${PART_KB:-0} )); [ "$shown" -gt "${TOT_KB:-0}" ] 2>/dev/null && shown=${TOT_KB:-0}
	printf '%s/%s\n' "$shown" "${TOT_KB:-0}" > "$SPROG"
	# RATE_F always names a file and awk never reads stdin: an unset RATE_F made awk block on the console
	# and froze the host mid-sync, B included (Brick Pro, 2026-09-22)
	[ -n "${RATE_F:-}" ] || RATE_F="$W/rate"
	pnow=$(now); printf '%s %s\n' "$pnow" "$shown" >> "$RATE_F" 2>/dev/null
	rate=$(awk -v n="$pnow" '$1 >= n-60 && !f { t0=$1; k0=$2; f=1 } { t1=$1; k1=$2 } END { if (f && t1-t0 >= 5 && k1 > k0) printf "%d", (k1-k0)/(t1-t0); else print 0 }' "$RATE_F" 2>/dev/null </dev/null)
	left=$((TOT_KB - shown)); [ "$left" -lt 0 ] && left=0   # per-file rounding can overshoot the total
	smsg "$1

$(fmt_kb "$shown") of $(fmt_kb "$TOT_KB"), $DONE_N of $TOT_N
$(eta "$left" "$rate") left"; }

# B makes status.elf exit, which runs GFX_quit and blacks the panel -- so the instant we notice a stop,
# put an UNCANCELLABLE status straight back. The script keeps working for a moment after a stop (finishing
# the file, tidying up), and a phase that runs with a dark screen is exactly what the plan forbids.
stop_ui(){ status "Stopping..."; }
# busybox httpd -vv logs TWO lines per request (url:/path then response:200); darkhttpd logs ONE. Count
# url: lines when the log has them so the bar advances per REQUEST on both, instead of running at 2x on
# busybox and pegging at 100% halfway through the transfer (2026-09-18 re-review).
served_count(){ u=$(grep -c 'url:' /tmp/dsync-httpd.log 2>/dev/null)
	if [ "${u:-0}" -gt 0 ]; then printf '%s' "$u"; else awk 'END{print NR+0}' /tmp/dsync-httpd.log 2>/dev/null; fi; }

# One file, with B honoured MID-download. A big file is fetched in the BACKGROUND and polled, so a stop
# kills wget at once instead of leaving the panel dark for the ~10 min a 700 MB image takes at 1.2 MB/s.
# A small one runs straight through: polling each of 400 saves would add a second to every one of them,
# and a save finishes inside one poll tick anyway.
# rc 3 = the user stopped; ANY other rc means "have a look at the file" -- the caller verifies size and
# hash, so wget's own status is never trusted and we never have to `wait` on a child a busybox shell may
# already have reaped. A few bytes landing after the kill are harmless: they fail that verification.
# A big file is bounded by PROGRESS, not by a clock: a wall-clock cap would shoot a legitimately slow
# 700 MB transfer in the head, so instead the destination has to keep GROWING. Thirty seconds with no
# new bytes is a stalled read, which is the case -T was supposed to cover before it turned out to
# segfault this busybox (see hget).
fetch_file(){ # <url> <dst> <bytes>
	if [ "${3:-0}" -lt 4194304 ]; then hget 20 -O "$2" "$1"; return 0; fi
	wget -q -O "$2" "$1" 2>/dev/null & wp=$!
	last=-1; stall=0
	while kill -0 "$wp" 2>/dev/null; do
		stopped && { kill "$wp" 2>/dev/null; return 3; }
		sleep 1
		sz=$(file_bytes "$2")
		if [ "$sz" = "$last" ]; then stall=$((stall+1)); else stall=0; last=$sz; fi
		PART_KB=$((sz / 1024)); [ -n "${PLABEL:-}" ] && prog "$PLABEL"
		[ "$stall" -ge 30 ] && { PART_KB=0; kill -9 "$wp" 2>/dev/null; return 0; }
	done
	PART_KB=0
	return 0; }

# ONE archive instead of one HTTP fetch per file: 116 saves took minutes as 116 wget forks (each with a
# shell fork for URL-encoding) and every spaced name was a fresh chance to 404. The side that OWNS the
# files tars them straight off the card (paths are relative to $LOCAL, so no symlinks, no -h, no -T --
# both absent on the Miyoo busybox), the peer pulls one stream and extracts into staging, and the
# existing size check then fetches only what the archive did not deliver. Over 400 files (Games on)
# stays per-file to keep the arg list sane.
bundle_plan(){ # <plan> <out.tar> -> 0 when the archive was written
	bp="$1"; bo="$2"   # `set --` below discards $1/$2, so hold them first
	n=$(plan_count "$bp"); [ "$n" -gt 0 ] || return 1
	# chunks of 400 paths keep every tar arg list far under ARG_MAX; chunk k>1 is <out>.k
	rm -f "$bo" "$bo".[0-9]*; k=1; c=0; cb=0; set --
	while IFS="$TAB" read -r act cls sz rel hash mtime; do
		[ -n "$rel" ] || continue
		[ -f "$SERVE/$rel" ] || continue     # gone since the manifest: one missing path failed the whole tar (QA 2026-09-20)
		[ "${sz:-0}" -lt 4194304 ] 2>/dev/null || continue   # >= 4 MiB streams on its own (fetch_file); the bundle is for the MANY small files
		# a chunk closes at 400 paths OR 200 MB, and BEFORE a file that would push it past the cap, so a chunk
		# is never bigger than max(200 MB, one file): the receiver holds one chunk beside its extracted files
		if [ "$c" -gt 0 ] && [ $((cb + ${sz:-0})) -gt 209715200 ]; then
			out="$bo"; [ "$k" -gt 1 ] && out="$bo.$k"
			tar -chf "$out" -C "$SERVE" "$@" 2>/dev/null || { rm -f "$bo" "$bo".[0-9]*; return 1; }
			k=$((k+1)); c=0; cb=0; set --
		fi
		set -- "$@" "$rel"; c=$((c+1)); cb=$((cb + ${sz:-0}))
		if [ "$c" -ge 400 ] || [ "$cb" -ge 209715200 ]; then
			out="$bo"; [ "$k" -gt 1 ] && out="$bo.$k"
			tar -chf "$out" -C "$SERVE" "$@" 2>/dev/null || { rm -f "$bo" "$bo".[0-9]*; return 1; }
			k=$((k+1)); c=0; cb=0; set --
		fi
	done < "$bp"
	if [ "$c" -gt 0 ]; then
		out="$bo"; [ "$k" -gt 1 ] && out="$bo.$k"
		tar -chf "$out" -C "$SERVE" "$@" 2>/dev/null || { rm -f "$bo" "$bo".[0-9]*; return 1; }
	fi
	[ -s "$bo" ]
}
# The outgoing archive lives on the CARD and is served through a symlink in $SERVE (build-export already
# serves every card file through symlinks, so httpd following them is proven on all three devices).
# $SERVE is /tmp, which is RAM: 49 MB on the Miyoo, where a handful of PS1 states already overflowed
# it, and a Games bundle would pin hundreds of MB on a 1 GB Brick (QA 2026-09-20). Skipped when the
# card cannot hold a second copy of the plan bytes; the per-file path then does the work.
bundle_out(){ # <plan> -> 0 when chunks are linked into $SERVE
	# bod, not bo: bundle_plan uses bo for ITS output path and clobbered ours (no local in busybox sh),
	# so this loop looked inside the tar for chunks and linked none: every bundle 404 today (2026-09-21)
	bod="$DS_DIR/out"; rm -rf "$bod"; rm -f "$SERVE"/_dsync_bundle.tar*
	sm=$(awk -F"$TAB" '$3 < 4194304 { b += $3 } END { printf "%d", (b + 1023) / 1024 }' "$1")   # only the small files ride in the bundle
	[ "${sm:-0}" -gt 0 ] || { dbg "bundle: nothing under 4 MiB to bundle"; return 1; }
	need=$(( sm * 11 / 10 + 2048 ))
	free=$(df -k "$LOCAL" 2>/dev/null | awk 'NR==2{print $4}')
	need=$((need + ${MNEED:-0}))     # plus the incoming apply this device already approved (Codex 2026-09-21)
	[ "${free:-0}" -gt "$need" ] 2>/dev/null || { dbg "bundle: skipped, ${free:-0} KB free < $need KB"; return 1; }
	mkdir -p "$bod" 2>/dev/null || return 1
	bundle_plan "$1" "$bod/_dsync_bundle.tar" || { dbg "bundle: tar failed for $(plan_count "$1") files"; rm -rf "$bod"; return 1; }
	bn=0; for bf in "$bod"/_dsync_bundle.tar*; do [ -f "$bf" ] && { ln -s "$bf" "$SERVE/${bf##*/}"; bn=$((bn+1)); }; done
	dbg "bundle: $bn chunk(s) linked, $(file_bytes "$bod/_dsync_bundle.tar") bytes first"; return 0; }
pull_plan(){ # <base url> <plan> <status label> : stage every planned file
	RATE_F="$W/rate"; : > "$RATE_F"; PART_KB=0
	# One stream first (see bundle_plan). A truncated or missing archive is harmless: whatever it did not
	# deliver at the right size is exactly what the resume split below fetches file by file.
	PULL_BUNDLED=0; bn=$(plan_count "$2")
	# totals BEFORE the bundle stage, so the screen never reads "0 KB of  KB" while chunks download; the
	# exact split is recomputed after resume-check below (the bundle chunks count as progress meanwhile)
	TOT_KB=$(plan_kb "$2"); TOT_N=$bn; DONE_KB=0; DONE_N=0
	# a RETRY with most files already staged goes straight to the per-file resume: re-pulling 320 MB of
	# bundles to get one missing file (Plus, 469 of 470, 2026-09-22) is exactly the wrong trade
	missing=$bn; [ -d "$STAGE" ] && missing=$(eng resume-check "$2" "$STAGE" 2>/dev/null | wc -l | tr -d ' ')
	if [ "$bn" -gt 1 ] && [ "${missing:-$bn}" -gt 20 ]; then
		BT="$DS_DIR/bundle.tar"; rm -f "$BT"
		bdl=$(( $(plan_kb "$2") / 50 + 40 ))     # assume >= 50 KB/s, plus slack: never shorter than the data
		prog "$3"
		k=1
		while :; do
			bu="$1/_dsync_bundle.tar"; [ "$k" -gt 1 ] && bu="$1/_dsync_bundle.tar.$k"
			hget_c "$bdl" "$BT" "$bu"; hrc=$?
			[ "$hrc" = 3 ] && { rm -f "$BT"; stop_ui; dbg "pull: stopped by user during bundle $k"; return 2; }
			[ "$hrc" = 0 ] && [ -s "$BT" ] || break
			mkdir -p "$STAGE" 2>/dev/null; tar -xf "$BT" -C "$STAGE" 2>/dev/null
			PULL_BUNDLED=1; dbg "pull: bundle $k $(file_bytes "$BT") bytes extracted"
			DONE_KB=$((DONE_KB + $(file_bytes "$BT") / 1024)); PART_KB=0; prog "$3"
			rm -f "$BT"; k=$((k+1)); [ "$k" -le 64 ] || break
		done
		rm -f "$BT"
	fi
	# Resume is the engine's call: a staged file is done when its size AND its hash match the plan, so a
	# half-downloaded file comes again and a verified one is never fetched twice. Split the plan into what
	# is already here (counted as progress) and what is left, in one pass -- no per-file grep.
	eng resume-check "$2" "$STAGE" > "$W/need" 2>/dev/null
	: > "$W/todo"; : > "$W/have"
	# FILENAME==ARGV[1], not FNR==NR: when resume-check returns NOTHING (a resume where every file was
	# already staged and verified) awk reads zero records from it, FNR==NR stays true for the PLAN too,
	# and every line lands in n[] instead of have -- a bar frozen at "0 of 40" (2026-09-18 review).
	awk -F"$TAB" -v todo="$W/todo" -v have="$W/have" 'FILENAME==ARGV[1]{n[$0]=1;next}{ if ($4 in n) print > todo; else print > have }' "$W/need" "$2"

	TOT_KB=$(plan_kb "$2"); TOT_N=$(plan_count "$2")
	DONE_KB=$(plan_kb "$W/have"); DONE_N=$(plan_count "$W/have")
	prog "$3"
	fail=0
	while IFS="$TAB" read -r act cls sz rel hash mtime; do
		[ -n "$rel" ] || continue
		mkdir -p "$STAGE/$(dirname "$rel")" 2>/dev/null
		try=0; okf=0; halt=0
		# retry each file, so a WiFi blip does not fail a whole sync
		while [ "$try" -lt 3 ]; do
			try=$((try+1))
			fetch_file "$1/$(net urlenc "$rel")" "$STAGE/$rel" "$sz"; frc=$?
			[ "$frc" = 3 ] && { rm -f "$STAGE/$rel"; halt=1; break; }
			staged_ok "$rel" "$sz" "${hash:--}" && { okf=1; break; }
			rm -f "$STAGE/$rel"
			stopped && { halt=1; break; }     # B during a small file: give up between attempts
		done
		[ "$halt" = 1 ] && { stop_ui; dbg "pull: stopped by user at $DONE_N/$TOT_N"; return 2; }
		if [ "$okf" = 1 ]; then DONE_N=$((DONE_N+1)); DONE_KB=$((DONE_KB + (sz+1023)/1024))
		else fail=$((fail+1)); dbg "pull: gave up on $rel"; fi
		prog "$3"
		stopped && { stop_ui; dbg "pull: stopped by user at $DONE_N/$TOT_N"; return 2; }
	done < "$W/todo"
	[ "$fail" -gt 0 ] && return 1
	return 0; }

# Prints how many files landed and RETURNS the engine's status. The status used to be thrown away (the
# function returned awk's), so a partial apply -- the card filling up mid-way is the realistic one -- was
# reported as "Synced!" and the `done` state then deleted the journal pointer and the staged bytes that
# were the only way to finish it. Call it as `apply_plan <plan> > file`, never in $(...): the globals it
# sets (BK) have to survive, and a command substitution would fork them away.
# TAG -> folder for THIS card (see sync-engine.sh local_rel): local folders first, then the peer's names for
# tags this card has no folder for yet, so a new system lands under the name the sender used
write_sysmap(){ : > "$W/sysmap"
	for d in "$LOCAL"/Roms/*/; do [ -d "$d" ] || continue; d=${d%/}; n=${d##*/}
		case "$n" in .*) continue ;; *"("*")") t=${n##*(}; t=${t%)} ;; *) t=$n ;; esac
		printf '%s\t%s\n' "$t" "$n" >> "$W/sysmap"; done
	[ -s "$W/peer.sys" ] && awk -F"$TAB" 'FILENAME==ARGV[1] { h[$1]=1; next } $1!="" && !($1 in h) && !s[$1]++' "$W/sysmap" "$W/peer.sys" >> "$W/sysmap"
	export DSYNC_SYSMAP="$W/sysmap"; }
apply_plan(){ # <plan>
	BK=""; write_sysmap
	if [ "$(plan_count "$1")" -eq 0 ]; then printf 0; return 0; fi
	BK="$BK_ROOT/$(ts)"; bn=1; while [ -e "$BK" ]; do bn=$((bn+1)); BK="$BK_ROOT/$(ts)-$bn"; done   # never reuse a dir (QA 2026-09-20)
	cp "$1" "$RES_PLAN" 2>/dev/null; printf '%s\n' "$BK" > "$RES_BK"   # so a power cut can be resumed
	eng apply-plan "$1" "$STAGE" "$LOCAL" "$BK" >> "$LOGF" 2>&1; arc=$?
	printf '%s, %s' "$PEER" "$(date '+%b %d %H:%M' 2>/dev/null)" > "$BK/label" 2>/dev/null
	eng prune "$BK_ROOT" 5 >/dev/null 2>&1
	awk -F"$TAB" '$1=="DONE" && $2!="keep" {n++} END{print n+0}' "$BK/journal.log" 2>/dev/null   # keep = live edit kept, nothing copied
	return "$arc"; }

# ---- library mode -------------------------------------------------------------------------------
# DSYNC_LIB=1 means this file was SOURCED by the on-device integration harness, which drives the REAL
# helpers below against a REAL peer instead of reimplementing them. In that mode nothing here may touch
# the radio, the screen, the traps or the sleep state -- and the state machine at the bottom never runs.
# This exists because every test we had ran on a Mac, where `wget -T` is a perfectly valid flag, so an
# option that SEGFAULTS the device's busybox sailed through 227 green assertions and four shipped
# builds. A suite that never touches the target hardware cannot catch a bug only that hardware has.
[ "${DSYNC_LIB:-0}" = 1 ] && return 0

# ============================== the state machine ==================================================
STATE=entry
BK=""            # the backup dir of the last apply; `done` checks ITS journal before clearing resume
while :; do
case "$STATE" in

entry)
	# a cut-short apply is urgent -- offer to finish it before anything else
	RESUME_BK=""; [ -s "$RES_BK" ] && RESUME_BK=$(cat "$RES_BK" 2>/dev/null)
	if [ -n "$RESUME_BK" ] && [ -d "$RESUME_BK" ]; then
		case "$(eng journal-status "$RESUME_BK" 2>/dev/null)" in
			INCOMPLETE*)
				ask "A sync was interrupted.

Finish it now? If it keeps failing,
X discards it." "RESUME" "NOT NOW" "DISCARD"; arc=$?
				if [ "$arc" = 0 ]; then STATE=resume; continue
				elif [ "$arc" = 2 ]; then rm -f "$RES_BK" "$RES_PLAN"; rm -rf "$STAGE"; mkdir -p "$STAGE" 2>/dev/null
				     tell "Discarded.

Your files were not changed." ; fi ;;
		esac
	fi
	# Opening the Tool IS pressing Sync: go straight to Searching (Dan, 2026-09-20: fewer screens). The
	# toggles live behind Y on the stepper (the options state below), and the first run ever, with
	# nothing turned on, lands there so there is something to sync.
	# Home first (Dan, 2026-09-20): the toggles and Backups stay visible and X Sync states intent before any
	# radio work starts. Y on the stepper still reopens this screen.
	STATE=options; continue ;;

options)
	# The settings-style options screen: three per-device toggles, remembered. B back, X backups, Y sync.
	# Both devices set their own; a category syncs only when BOTH have it on. Sized like the main Settings
	# screen (natural widest-row width, no --wide); the bottom button bar takes the description row.
	set -- saves     "Saves"        "On|Off" "$(onoff "$PS")" ""
	set -- "$@" games   "Games"       "On|Off" "$(onoff "$PG")" ""
	set -- "$@" configs "Game Configs" "On|Off" "$(onoff "$PC")" ""
	menu --title "Sync Device" --x-label "Sync" --y-label "Backups" "$@" > "$W/out"
	while IFS= read -r line; do case "$line" in
		saves=On) PS=1 ;; saves=Off) PS=0 ;;
		games=On) PG=1 ;; games=Off) PG=0 ;;
		configs=On) PC=1 ;; configs=Off) PC=0 ;;
	esac; done < "$W/out"
	save_prefs
	case "$(sed -n 's/^ACTION=//p' "$W/out" | head -1)" in
		x) STATE=find ;;   # all off is allowed: this device then takes nothing and only gives (per-direction toggles)
		y) STATE=backups ;;
		*) exit 0 ;;   # B (no ACTION line): leave. It used to fall into find and start searching (QA 2026-09-20)
	esac ;;

backups)
	if [ -z "$(ls -A "$BK_ROOT" 2>/dev/null)" ]; then
		tell "No backups yet.

A backup is made automatically
whenever a sync replaces a file."; STATE=entry; continue
	fi
	# A = restore the most recent, X = delete them all, B = back
	ask "Backups

Restore puts this device back to an
earlier state (current files are backed
up first). Delete frees their space." "RESTORE" "BACK" "DELETE ALL"; rc=$?
	case "$rc" in
		0) STATE=restore ;;
		2) if ask "Delete all sync backups?

This cannot be undone." "DELETE" "BACK"; then
		       rm -rf "$BK_ROOT"/* 2>/dev/null; tell "Backups deleted."
		   fi; STATE=entry ;;
		*) STATE=entry ;;
	esac ;;

find)
	status_steps "1
Open Device Sync on the other device"
	net stop-serve >/dev/null 2>&1      # a retry must not leave the previous run's httpd orphaned
	# ...and must not leave the previous pass's RADIO up either. An AP left running keeps broadcasting
	# while we start a fresh pass, and ap_alive is only `pidof hostapd`, so the stale process reports the
	# new hotspot as up; an association left over from a join keeps answering the peer's pings, so it
	# never notices we left. Every pass starts from a clean radio (2026-09-18 review).
	net ap-down >/dev/null 2>&1
	[ "${ROLE:-}" = join ] && net wifi-off >/dev/null 2>&1
	ROLE=""
	radio_up
	# 1) is somebody already hosting? an iw scan takes ~2 s of its own, so two passes is the ~4 s window
	FOUND=""; i=0
	while [ "$i" -lt 2 ]; do
		FOUND=$(peer_ssid "$MYSSID" "$(net scan 2>/dev/null)")
		[ -n "$FOUND" ] && break
		i=$((i+1))
	done
	PEER_IP=""; HALT=0
	if [ -n "$FOUND" ]; then ROLE=join; else ROLE=host; fi
	dbg "find role=$ROLE me=$MYSSID found=$FOUND"

	if [ "$ROLE" = host ]; then
		net ap-up "$MYSSID" "$PSK" >/dev/null 2>&1
		if ! ap_alive; then
			# A single-radio Realtek part (Miyoo 8188fu) may have no working AP mode, but it can still
			# JOIN. Rather than dead-end on "Could not open the hotspot", fall back to a patient joiner
			# and let a host-capable peer (a Brick, true 2nd radio) host. Only a concurrent-radio device
			# treats a hosting failure as a real fault.
			if [ "${DSYNC_CONCURRENT:-0}" = 1 ]; then
				if oops "Could not open the hotspot.

Try again?"; then continue; else exit 0; fi
			fi
			net ap-down >/dev/null 2>&1; radio_up
			dbg "find: cannot host on this radio -> waiting to join a host-capable peer"
			i=0
			while [ "$i" -lt 600 ]; do
				FOUND=$(peer_ssid "$MYSSID" "$(net scan 2>/dev/null)")
				[ -n "$FOUND" ] && break
				stopped && { HALT=1; break; }
				sleep 3; i=$((i+3))
			done
			if [ -n "$FOUND" ]; then ROLE=join
			elif [ "$HALT" != 1 ]; then
				tell "Could not connect.

Open Device Sync on a TrimUI Brick,
which can host for this device."; exit 0
			fi
		fi
	fi
	if [ "$ROLE" = host ] && ap_alive; then
		# WAIT PATIENTLY. The other device is picked up and driven BY A HUMAN, so the gap between the two
		# Sync presses is however long it takes Dan to put one down and pick the other up. The old window
		# was 60 x 2 s and then it re-elected under a new name, which orphaned a peer that had just
		# associated -- the exact shape of the first real run's failure (2026-09-18). Ten minutes, and B
		# ends it at any point, so patience costs the user nothing.
		i=0
		while [ "$i" -lt 600 ]; do
			if [ "$(net sta-count)" -ge 1 ]; then
				step "2
Found a device"   # a station associated -> Connecting
				# An association is not an address. Wait for the lease: the pool is .10-.20, and a joiner
				# still finishing DHCP would fail the very first liveness check if we guessed (Codex).
				dbg "find: station associated, resolving its address"
				j=0
				while [ "$j" -lt 60 ]; do
					PEER_IP=$(arp_peer_ip "$(cat /proc/net/arp 2>/dev/null)" "$AP_IP")
					[ -z "$PEER_IP" ] && PEER_IP=$(peer_probe)
					[ -n "$PEER_IP" ] && break
					stopped && { HALT=1; break; }
					sleep 2; j=$((j+2))
				done
				break
			fi
			stopped && { HALT=1; break; }
			# Scan for a rival hotspot ONLY in a short early window. This radio is shared between the AP
			# and the station, so an iw scan takes our own hotspot off channel for seconds -- scanning
			# every 10 s for the whole wait is what made the Brick Pro never notice the Brick that had
			# ALREADY associated and taken a lease from it (device logs, 2026-09-18). Both-elected-host
			# only happens when the two Sync presses land within seconds of each other, so three scans
			# across the first ~30 s cover it; after that one scan every 40 s (a Miyoo opened later can
			# only host, and we must notice it), rare enough not to break a join in progress.
			case "$i" in 0|8|20|60|100|140|180|220|260|300|340|380|420|460|500|540|580)
				Y=$(yield_to "$MYSSID" "$(net scan 2>/dev/null)")
				if [ -n "$Y" ]; then
					dbg "find: yielding to $Y (lower token)"
					net ap-down >/dev/null 2>&1; FOUND=$Y; ROLE=join; break
				fi ;;
			esac
			sleep 2; i=$((i+2))
		done
	fi
	if [ "$HALT" = 1 ]; then
		if [ "${STOP_RC:-1}" = 2 ]; then STOP_RC=1; net ap-down >/dev/null 2>&1; STATE=options; continue; fi
		tell "Stopped.

Nothing was copied."; exit 0
	fi
	if [ "$ROLE" = join ]; then
		# join blocks for up to 90 s of association and DHCP retries, so run it BESIDE the screen rather
		# than in front of it: held in the foreground, B did nothing for a minute and a half and a
		# force-quit was the only way out (Codex, 2026-09-18).
		PN=${FOUND#MinUI-Sync-????-}; [ "$PN" = "$FOUND" ] && PN="a device"   # the name rides in the SSID
		step "2
Found $PN"   # found a hotspot, joining it -> Connecting
		rm -f "$W/joinip" "$W/joinip.tmp" "$W/join.pid"
		# the join runs as a known pid inside the wrapper: killing only the wrapper left the join and its
		# 90 s udhcpc loop running beside the restored home network (QA 2026-09-20)
		( sh "$NET" join "$FOUND" "$PSK" > "$W/joinip.tmp" 2>/dev/null & jp=$!; printf '%s' "$jp" > "$W/join.pid"; wait "$jp"; mv "$W/joinip.tmp" "$W/joinip" ) & JPID=$!
		j=0
		while kill -0 "$JPID" 2>/dev/null && [ "$j" -lt 150 ]; do
			stopped && { HALT=1; break; }
			sleep 2; j=$((j+2))
		done
		if kill -0 "$JPID" 2>/dev/null; then kill "$(cat "$W/join.pid" 2>/dev/null)" "$JPID" 2>/dev/null; fi
		MYIP=$(head -1 "$W/joinip" 2>/dev/null)
		PEER_IP="$AP_IP"; [ -n "$MYIP" ] || PEER_IP=""
		dbg "find: joined $FOUND as $MYIP"
		if [ "$HALT" = 1 ]; then
			if [ "${STOP_RC:-1}" = 2 ]; then STOP_RC=1; net ap-down >/dev/null 2>&1; STATE=options; continue; fi
			tell "Stopped.

Nothing was copied."; exit 0
		fi
	fi
	if [ -z "$PEER_IP" ]; then
		net ap-down >/dev/null 2>&1
		if oops "Couldn't find your other device.

Open Device Sync there and pick Sync,
then try again."; then continue; else exit 0; fi
	fi
	PEER_BASE="http://$PEER_IP:$PORT"
	STATE=compare ;;

compare)
	# the name stays under the row from the moment we have it (Dan, 2026-09-22): the joiner knows it from the
	# SSID already; the host asks the joiner for it NOW, before its own 10-20 s file walk, two quick tries
	if [ -z "${PN:-}" ] && [ -n "${PEER_IP:-}" ]; then
		pi=0; while [ "$pi" -lt 2 ] && [ -z "${PN:-}" ]; do PN=$(hget 3 -O - "http://$PEER_IP:$PORT/_dsync_name" | head -c 200 | tr -cd 'A-Za-z0-9 ._()+-' | cut -c1-40) || PN=""; pi=$((pi+1)); done
	fi
	if [ -n "${PN:-}" ] && [ "$PN" != "a device" ]; then step "3
Comparing with $PN"; else step "3
Comparing libraries"; fi
	scope_list > "$W/scope"
	net build-export "$LOCAL" "$SERVE" --list "$W/scope" >/dev/null 2>&1
	printf '%s' "$NAME" > "$SERVE/_dsync_name"
	date +%s > "$SERVE/_dsync_now"        # our clock, so the peer can correct our mtimes into ITS time
	# and when this session's clock started: a no-RTC device restores its clock at boot, so only files
	# written since then carry the lag the peer measures now (older ones are compared raw)
	NB=$(now); UP=$(cut -d. -f1 /proc/uptime 2>/dev/null); case "$UP" in ''|*[!0-9]*) UP=0 ;; esac
	MY_BOOT=0; [ "$NB" != 0 ] && { MY_BOOT=$((NB - UP)); printf '%s\n' "$MY_BOOT" > "$SERVE/_dsync_boot"; }
	printf 'S=%s G=%s C=%s P=%s F=%s V=%s K=%s\n' "$PS" "$PG" "$PC" "$DSYNC_PROTO" "$DSYNC_FORK" "$DSYNC_VER" "$GSKIP" > "$SERVE/_dsync_prefs"   # toggles + protocol (gate) + fork/build (label) + skipped systems
	df -k "$LOCAL" 2>/dev/null | awk 'NR==2{print $4}' > "$SERVE/_dsync_free"
	cp "$SERVE/_dsync_manifest" "$W/my.mf" 2>/dev/null
	# bind to the sync interface only: a concurrent host (Brick, Miyoo) would otherwise serve its saves
	# to the whole home LAN for the run (QA 2026-09-20). serve falls back to all interfaces if the bind fails.
	if [ "$ROLE" = host ]; then BINDIP=$AP_IP; else BINDIP=$MYIP; fi
	if ! net serve "$SERVE" "$PORT" "$BINDIP" >/dev/null 2>&1; then
		if oops "This device cannot share files.

Try again?"; then STATE=find; continue; else exit 0; fi
	fi
	# The peer may still be building its export, so poll rather than fail -- but say what we are actually
	# doing while we do it. This screen used to keep claiming "Comparing your libraries..." for four
	# silent minutes while the truth was that the other device had not answered yet (Dan, 2026-09-18).
	# The peer NAME is a tiny request: fetch it first so the stepper says WHO was found while the (much
	# larger) file lists exchange. Both sides publish _dsync_name before serve().
	PEER=""; pn=0
	while [ "$pn" -lt 6 ] && [ -z "$PEER" ]; do PEER=$(hget 6 -O - "$PEER_BASE/_dsync_name" | head -c 200 | tr -cd 'A-Za-z0-9 ._()+-' | cut -c1-40) || PEER=""; pn=$((pn+1)); [ -n "$PEER" ] || sleep 1; done
	# the host may still be building its file list (10-20 s on a big card) and not serving yet: fall back
	# to the name that rode in its SSID, and refresh once the list fetch below has proven it is up
	[ -z "$PEER" ] && PEER="${PN:-the other device}"
	step "3
Comparing with $PEER"
	fetch_live "$PEER_BASE/_dsync_manifest" "$W/peer.mf" 240 "$PEER_IP"; rc=$?
	hget 8 -O "$W/peer.sys" "$PEER_BASE/_dsync_systems" >/dev/null 2>&1 || : > "$W/peer.sys"   # its folder name per tag
	if [ "$rc" = 0 ] && { [ "$PEER" = "${PN:-}" ] || [ "$PEER" = "the other device" ]; }; then pn2=$(hget 6 -O - "$PEER_BASE/_dsync_name" | head -c 200 | tr -cd 'A-Za-z0-9 ._()+-' | cut -c1-40); [ -n "$pn2" ] && PEER=$pn2; fi
	if [ "$rc" = 2 ]; then
		tell "Stopped.

Nothing was copied."; exit 0
	fi
	if [ "$rc" != 0 ]; then
		dbg "lost: rc=$rc at ${STATE}"
		if oops "Lost the other device.

Try again?"; then STATE=find; continue; else exit 0; fi
	fi
	step "3
Comparing with $PEER"   # the row says Connected, the caption says why you wait
	# A fetch that timed out may still have delivered a PREFIX of the body, and hget reports that with a
	# non-zero status -- so a captured value is only usable when the status says the fetch COMPLETED.
	# This matters most for the free-space figure: a truncated decimal is a smaller VALID number, so
	# "15000000" arriving as "150" invents a "Not enough space" refusal that replaces the Sync button
	# outright and quotes a fabricated shortfall (sweep, 2026-09-18).
	PEER_FREE=$(hget 8 -O - "$PEER_BASE/_dsync_free") || PEER_FREE=""
	# CLOCK SKEW: newest-wins compares mtimes from two clocks, and the Miyoo has no RTC. Read the peer's
	# clock and shift ITS mtimes into OUR time before deciding. Under 2 min is network/boot jitter: ignore.
	PEER_NOW=$(hget 8 -O - "$PEER_BASE/_dsync_now") || PEER_NOW=""
	NOWM=$(now); case "$PEER_NOW" in ''|*[!0-9]*) CLK_OFF=0 ;; *) if [ "$NOWM" != 0 ]; then CLK_OFF=$(( NOWM - PEER_NOW )); else CLK_OFF=0; fi ;; esac
	PEER_BOOT=$(hget 6 -O - "$PEER_BASE/_dsync_boot") || PEER_BOOT=""; case "$PEER_BOOT" in ''|*[!0-9]*) PEER_BOOT=0 ;; esac
	[ "$CLK_OFF" -gt -120 ] && [ "$CLK_OFF" -lt 120 ] && CLK_OFF=0
	dbg "compare: clock offset me-peer=${CLK_OFF}s"
	# the peer's toggles. Saves/Configs are small and safe to default ON (so an OLD peer with no prefs
	# endpoint still syncs the common case), but Games defaults OFF: a timed-out prefs read must NEVER let
	# the host push a 24 GB library onto a device that turned Games off (Codex, 2026-09-18). Retry the
	# tiny file a couple of times before giving up.
	QS=1; QG=0; QC=1
	PP=""; ppi=0
	while [ "$ppi" -lt 3 ]; do PP=$(hget 6 -O - "$PEER_BASE/_dsync_prefs") && [ -n "$PP" ] && break; PP=""; ppi=$((ppi+1)); done
	case "$PP" in *S=0*) QS=0 ;; esac
	case "$PP" in *G=1*) QG=1 ;; esac   # Games ON only when the peer EXPLICITLY says so
	case "$PP" in *C=0*) QC=0 ;; esac
	QK=$(printf '%s\n' "$PP" | sed -n 's/.*K=\([^ ]*\).*/\1/p' | head -1)   # systems the peer skips: honoured whoever hosts
	# protocol check: a peer that publishes prefs but a different P (or none: a pre-v2 build) cannot be
	# trusted to read our plan/bundle. Say which side to update, then leave cleanly (the peer sees ABORT).
	PPROTO=$(printf '%s\n' "$PP" | sed -n 's/.*P=\([0-9]*\).*/\1/p' | head -1)
	if [ -n "$PP" ] && [ "${PPROTO:-0}" != "$DSYNC_PROTO" ]; then
		printf 'ABORT\n' > "$SERVE/_dsync_totals"
		if [ "${PPROTO:-0}" -lt "$DSYNC_PROTO" ] 2>/dev/null; then WHO="$PEER"; else WHO="this device"; fi
		PFORK=$(printf '%s\n' "$PP" | sed -n 's/.*F=\([^ ]*\).*/\1/p' | head -1)
		PVER=$(printf '%s\n' "$PP" | sed -n 's/.*V=\([^ ]*\).*/\1/p' | head -1)
		tell "Device Sync versions differ.

$PEER: ${PFORK:-unknown} ${PVER:-build} (sync v${PPROTO:-1})
This device: $DSYNC_FORK $DSYNC_VER (sync v$DSYNC_PROTO)

Update $WHO, then try again.
Nothing was copied."; exit 0
	fi
	# A is ALWAYS the host and B always the joiner, on both devices, so the one plan reads the same way
	# on each. "(this one)" always lands on the device you are holding.
	disambiguate "$NAME" "$PEER" > "$W/names"
	if [ "$ROLE" = host ]; then ANAME=$(sed -n 1p "$W/names"); BNAME=$(sed -n 2p "$W/names")
	else                        ANAME=$(sed -n 2p "$W/names"); BNAME=$(sed -n 1p "$W/names"); fi
	dbg "compare peer=$PEER files=$(awk 'END{print NR+0}' "$W/peer.mf")"
	if [ "$ROLE" = host ]; then STATE=review; else STATE=wait_plan; fi ;;

review)
	# ONE screen. Merge the two snapshots, keep the NEWER copy of anything that changed on both (older
	# backed up, restorable), and show a single "N differ. Sync?". No category toggles, no drill-in, no
	# conflict screen: the whole flow is snapshot, compare, sync (Dan, 2026-09-18: "KEEP IT SIMPLE").
	# Games are never touched destructively -- a ROM on both devices is skip-by-name, a ROM on one is
	# copied to the other, nothing is ever overwritten or deleted, so a game can never be lost.
	eng merge "$W/my.mf" "$W/peer.mf" "${CLK_OFF:-0}" "${PEER_BOOT:-0}" "${MY_BOOT:-0}" > "$W/merge"   # skew-corrected newest-wins for every class
	if [ "$(awk -F"$TAB" '$1!="skip"{n++} END{print n+0}' "$W/merge")" -eq 0 ]; then
		# the peer is still waiting on us, so say WHY we are finishing (a "cancelled" here would be a lie)
		printf 'NOTHING\n' > "$SERVE/_dsync_totals"
		sleep 2
		tell "Already in sync.

Nothing to copy."; exit 0
	fi
	auto_resolve "$W/my.mf" "$W/peer.mf" "$W/merge" > "$DEC"
	# per-system choice for Games: a 25 GB library all-or-nothing was unusable (Dan, 2026-09-21). Shown on
	# the host only (it owns the plan), B here cancels like B on the item list.
	if [ "$PG" = 1 ] || [ "$QG" = 1 ]; then
		NROM0=$(awk -F"$TAB" '$1!="skip" && $2=="rom"' "$W/merge" | wc -l | tr -d ' ')
		if [ -n "$QK" ]; then drop_systems "$W/merge" "$QK" > "$W/merge.f" && mv "$W/merge.f" "$W/merge"; fi   # the peer's skips first: not offered here
		write_sysmap; sys_rows "$W/merge" "$W/sysmap" > "$W/sys"
		if [ -s "$W/sys" ]; then
			set --
			while IFS="$TAB" read -r st sn sc sk; do
				cur=Sync; in_csv "$st" "$GSKIP" && cur=Skip
				set -- "$@" "sys_$st" "$sn ($sc games, $(fmt_kb "$sk"))" "Sync|Skip" "$cur" ""
			done < "$W/sys"
			menu --title "Games to sync" --x-label "Continue" "$@" > "$W/out"
			if ! grep -q '^ACTION=x$' "$W/out"; then
				printf 'ABORT\n' > "$SERVE/_dsync_totals"; status "Cancelling..."; sleep 3
				dbg "review: cancelled at the system picker"; exit 0
			fi
			# rows the user left untouched are not echoed back, so start from the remembered list
			nskip=""
			while IFS="$TAB" read -r st sn sc sk; do
				v=$(sed -n "s/^sys_$st=//p" "$W/out" | tail -1)
				case "$v" in Skip) nskip="${nskip:+$nskip,}$st" ;; Sync) ;; *) in_csv "$st" "$GSKIP" && nskip="${nskip:+$nskip,}$st" ;; esac
			done < "$W/sys"
			GSKIP=$nskip; save_prefs
			drop_systems "$W/merge" "$GSKIP" > "$W/merge.f" && mv "$W/merge.f" "$W/merge"
			dbg "review: games skip=[$GSKIP] peer=[$QK]"
		fi
		NROM1=$(awk -F"$TAB" '$1!="skip" && $2=="rom"' "$W/merge" | wc -l | tr -d ' '); NDROP=$((NROM0 - NROM1))
	fi
	# per direction: what the peer takes follows the PEER toggles, what we take follows OURS
	SKIPB=$(skip_classes "$QS" "$QG" "$QC"); SKIPA=$(skip_classes "$PS" "$PG" "$PC")
	dbg "review: skip to-peer=[$SKIPB] to-me=[$SKIPA] mine=S$PS/G$PG/C$PC peer=S$QS/G$QG/C$QC"
	build_plan "$W/merge" "$DEC" "$SKIPB" to-b "$W/my.mf" "$W/peer.mf" > "$W/plan.peer"
	build_plan "$W/merge" "$DEC" "$SKIPA" to-a "$W/my.mf" "$W/peer.mf" > "$W/plan.me"
	TOTN=$(( $(plan_count "$W/plan.peer") + $(plan_count "$W/plan.me") ))
	PK=$(plan_kb "$W/plan.peer"); MK=$(plan_kb "$W/plan.me")
	if [ "$TOTN" -eq 0 ]; then
		printf 'NOTHING\n' > "$SERVE/_dsync_totals"; sleep 2
		NDIFF=$(awk -F"$TAB" '$1!="skip"' "$W/merge" | wc -l | tr -d ' ')
		if [ "${NDROP:-0}" -gt 0 ]; then tell "Already in sync.

Only skipped systems differ."
		elif [ "${NDIFF:-0}" -gt 0 ]; then tell "Nothing to copy
with the current settings.

Turn on a category on the
device that should receive it."
		else tell "Already in sync.

Nothing to copy."; fi; exit 0
	fi

	# Space is still checked on BOTH cards, but it can now only ADD a warning, never hide the button.
	# plan-need sizes the real on-card backups for THIS device; the peer (no dst here) keeps the estimate.
	MYFREE=$(df -k "$LOCAL" 2>/dev/null | awk 'NR==2{print $4}')
	PNEED=$(need_kb "$PK")
	MNEED=$(eng plan-need "$W/plan.me" "$LOCAL" 2>/dev/null); case "$MNEED" in ''|*[!0-9]*) MNEED=$(need_kb "$MK") ;; esac
	SHORT=""
	[ -n "$PEER_FREE" ] && [ "$PEER_FREE" -lt "$PNEED" ] 2>/dev/null && SHORT="$PEER needs $(fmt_kb $((PNEED - PEER_FREE))) free"
	[ -n "$MYFREE" ]   && [ "$MYFREE"   -lt "$MNEED" ] 2>/dev/null && SHORT="${SHORT:+$SHORT, }this device needs $(fmt_kb $((MNEED - MYFREE))) free"
	if [ -n "$SHORT" ]; then
		printf 'ABORT\n' > "$SERVE/_dsync_totals"
		status "Cancelling..."; sleep 3
		tell "Not enough space.

$SHORT.
Nothing was copied."; exit 0
	fi

	# the ONE confirmation. A = sync, B = cancel (the universal back). Nothing has moved yet.
	plan_names "$W/plan.me" "$W/plan.peer" > "$W/names"
	NN=$(awk 'END{print NR+0}' "$W/names")
	set --
	ni=0
	while IFS="$TAB" read -r pnm ptyp; do
		ni=$((ni+1))
		# a single-value row (VALUES=type) is display-only: A cannot open/exit it, only Y syncs / B backs
		set -- "$@" "row$ni" "$pnm" "$ptyp" "$ptyp" ""
	done < "$W/names"
	# the ONE confirmation: a scrollable list of exactly WHAT will sync, by name -- "4 files (3 saves)"
	# told the user nothing they could act on (Dan, 2026-09-19). Y = sync, B = back. Nothing moved yet.
	if menu --wide --title "Sync $NN items, $(fmt_kb $((PK + MK)))" --a-label SYNC "$@" | grep -q '^ACTION=a$'; then
		bundle_out "$W/plan.peer"
		cp "$W/plan.me" "$SERVE/_dsync_want"
		cp "$W/plan.peer" "$SERVE/_dsync_plan"
		printf '%s %s 0\n' "$(plan_count "$W/plan.me")" "$(plan_count "$W/plan.peer")" > "$SERVE/_dsync_totals"
		dbg "review: SYNC me=$(plan_count "$W/plan.me") peer=$(plan_count "$W/plan.peer")"
		STATE=sync
	else
		# tell the peer we backed out, then leave -- it polls _dsync_totals every ~2 s, so KEEP SERVING a
		# few cycles or it reports "Lost the other device" for a deliberate cancel (the EXIT trap fires in
		# milliseconds). The status keeps the panel lit meanwhile.
		printf 'ABORT\n' > "$SERVE/_dsync_totals"
		status "Cancelling..."; sleep 3
		dbg "review: cancelled"; exit 0
	fi ;;

wait_plan)
	# the joiner never recomputes anything: it waits for the host's plan and obeys it
	# The same liveness and escape as every other wait in this file. Without them a host that quit or
	# whose battery died left this screen frozen for 30 min to 2.5 h with no button doing anything: the
	# status was launched WITHOUT --cancel-b, so status.elf never even read the pad (2026-09-18 review).
	# not in control here: the host is looking at the file list. Say whose hands the sync is in.
	status_sync "Use $PEER
to start the sync."
	i=0; miss=0; TOTALS=""; HALT=0
	while [ "$miss" -lt 5 ] && [ "$i" -lt 1800 ]; do
		TOTALS=$(hget 8 -O - "$PEER_BASE/_dsync_totals") || TOTALS=""   # a partial body is not an answer
		[ -n "$TOTALS" ] && break
		if ping -c1 -W2 "$PEER_IP" >/dev/null 2>&1; then miss=0; else miss=$((miss+1)); fi
		stopped && { stop_ui; HALT=1; break; }
		sleep 2; i=$((i+2))
	done
	if [ "$HALT" = 1 ]; then
		if [ "${STOP_RC:-1}" = 2 ]; then STOP_RC=1; net ap-down >/dev/null 2>&1; STATE=options; continue; fi
		tell "Stopped.

Nothing was copied."; exit 0
	fi
	case "$TOTALS" in
		"")        dbg "lost: no totals after the wait (${STATE})"; if oops "Lost the other device.

Try again?"; then STATE=find; continue; else exit 0; fi ;;
		NOTHING*)  tell "Already in sync.

Nothing to copy."; exit 0 ;;
		ABORT*)    tell "Sync cancelled on $PEER.

Nothing was copied."; exit 0 ;;
	esac
	fetch_live "$PEER_BASE/_dsync_plan" "$W/plan.me" 60 "$PEER_IP"; rc=$?
	if [ "$rc" = 2 ]; then
		tell "Stopped.

Nothing was copied."; exit 0
	fi
	if [ "$rc" != 0 ]; then
		dbg "lost: rc=$rc at ${STATE}"
		if oops "Lost the other device.

Try again?"; then STATE=find; continue; else exit 0; fi
	fi
	MNEED=$(eng plan-need "$W/plan.me" "$LOCAL" 2>/dev/null); case "$MNEED" in ''|*[!0-9]*) MNEED=0 ;; esac   # so bundle_out leaves room for it
	if hget 20 -O "$W/want" "$PEER_BASE/_dsync_want" && [ -s "$W/want" ]; then
		bundle_out "$W/want"
	fi
	dbg "wait_plan: got plan $(plan_count "$W/plan.me") files, totals=$TOTALS"
	STATE=sync ;;

sync)
	# A FRESH sync starts from an EMPTY staging dir. Downloads land in $STAGE (on the card, so a drop is
	# resumable), and resume-check skips a staged file whose SIZE matches -- correct for a resume of THIS
	# plan, but a stale same-size file left by an earlier failed sync (possibly with a different peer)
	# would be accepted and applied as current. A resume runs in STATE=resume, never here, so clearing on
	# entry to this state only ever wipes leftovers a fresh run must not trust (Codex, 2026-09-18).
	# ...but a RETRY of the same plan (connection lost, Sync again) KEEPS what already arrived: the plan
	# file is the identity, and resume-check re-verifies every staged file by size and hash. Without
	# this a blip at 1.9 GB of 2 GB restarted from zero (QA 2026-09-20).
	if [ -f "$STAGE/.plan" ] && cmp -s "$STAGE/.plan" "$W/plan.me" 2>/dev/null; then dbg "sync: same plan, staging kept"
	else rm -rf "$STAGE"; mkdir -p "$STAGE" 2>/dev/null; cp "$W/plan.me" "$STAGE/.plan" 2>/dev/null; fi
	# ONE status process per PHASE, not per tick -- allocating the display once was the CMA fix (killing
	# and relaunching a GFX tool per update is what fragmented the DE's contiguous memory and crashed the
	# Plus, 2026-09-18). The apply gets its own, WITHOUT --cancel-b: it cannot be stopped half-way, and
	# leaving B armed through it let one press black the panel out for the whole multi-GB write. Three
	# long-lived processes across a whole sync, never more.
	status_sync "Syncing with $PEER..."
	GOT=0; DONE_TEXT=""
	if [ "$ROLE" = join ]; then
		pull_plan "$PEER_BASE" "$W/plan.me" "Syncing with $PEER..."; rc=$?
		if [ "$rc" = 2 ]; then
			if oops "Stopped.

Nothing was half-copied.
Pick Sync again to finish." "SYNC AGAIN"; then STATE=find; continue; else exit 0; fi
		fi
		if [ "$rc" = 1 ]; then
			# say what happened, as the host side does: a peer that still answers means some ITEMS failed
			# after their retries, not the link (Brick with the Smart Pro, 2026-09-22)
			if ping -c1 -W2 "$PEER_IP" >/dev/null 2>&1; then MM="Could not copy everything."; else MM="Connection lost."; fi
			if oops "$MM

Pick Sync again to finish;
what already arrived is kept." "SYNC AGAIN"; then STATE=find; continue; else exit 0; fi
		fi
		status_off; status "Syncing with $PEER..."      # B off: nothing here can stop safely
		apply_plan "$W/plan.me" > "$W/got"; arc=$?
		GOT=$(cat "$W/got" 2>/dev/null); [ -n "$GOT" ] || GOT=0
		if [ "$arc" != 0 ]; then
			# a partial apply is resumable and must NOT be reported as done -- the engine left the
			# journal and the staged bytes exactly so this can be finished
			RESUME_BK="$BK"
			if oops "Could not save everything.

Nothing was lost.
Finish it now?" "FINISH"; then STATE=resume; continue; else exit 0; fi
		fi
		status_sync "Syncing with $PEER..."
		# Wait for the host to finish its half and publish the Done counts. Five lost pings (~25 s) mean
		# it is gone. The _dsync_applied request goes out EVERY pass, not once: the host learns we applied
		# only from that request, and a single fire-and-forget one that got lost hung both devices for
		# hours (2026-09-18 review). Re-sending is free -- the host breaks on the first sighting.
		i=0; miss=0; DONE_RAW=""; HALT=0
		while [ "$miss" -lt 5 ] && [ "$i" -lt 10800 ]; do
			hget 8 -O /dev/null "$PEER_BASE/_dsync_applied_$GOT"
			DONE_RAW=$(hget 8 -O - "$PEER_BASE/_dsync_done") || DONE_RAW=""  # ditto: half a line is not a report
			[ -n "$DONE_RAW" ] && break
			if ping -c1 -W2 "$PEER_IP" >/dev/null 2>&1; then miss=0; else miss=$((miss+1)); fi
			stopped && { stop_ui; HALT=1; break; }
			sleep 3; i=$((i+3))
		done
		# B here kills the host's IN-FLIGHT pull from us, so it is never a finished sync either
		[ "$HALT" = 1 ] && DONE_RAW=""
		if [ -n "$DONE_RAW" ]; then
			# counts, not a sentence: render it with OUR labels (see done_text)
			set -- $(printf '%s\n' "$DONE_RAW" | awk '{print $1+0, $2+0, $3+0; exit}')
			DONE_TEXT=$(done_text "$1" "$2" "$3" "$ANAME" "$BNAME")
		else
			# Stopped, or the host died / a failure sent it back to FIND while we waited for a message it
			# will never publish. Our half landed: say exactly that. Falling through to `done` used to
			# print "Synced!" for a half-finished run, and this still runs its staging cleanup.
			DONE_TEXT="Stopped.

This device is up to date.
$PEER may not have finished.
Pick Sync again there."
		fi
	else
		# the joiner pulls first; watch our httpd log to turn its downloads into a live bar
		BASE_LINES=$(served_count)
		# bytes actually sent over the hotspot radio: the only counter that moves INSIDE a 100 MB game
		# (the request count stood still for minutes and the host looked frozen, Dan 2026-09-22)
		TXF="/sys/class/net/$AP_IF/statistics/tx_bytes"; BASE_TX=$(cat "$TXF" 2>/dev/null); case "$BASE_TX" in ''|*[!0-9]*) BASE_TX="" ;; esac
		TOT_N=$(plan_count "$W/plan.peer"); TOT_KB=$(plan_kb "$W/plan.peer"); DONE_N=0; DONE_KB=0; RATE_F="$W/rate"; : > "$RATE_F"; PART_KB=0
		prog "Syncing with $PEER..."
		miss=0; i=0; PEER_GOT=""; HALT=0
		while [ "$miss" -lt 5 ] && [ "$i" -lt 10800 ]; do
			PEER_GOT=$(grep -o "_dsync_applied_[0-9]*" /tmp/dsync-httpd.log 2>/dev/null | tail -1)
			[ -n "$PEER_GOT" ] && break
			if ping -c1 -W2 "$PEER_IP" >/dev/null 2>&1; then miss=0; else miss=$((miss+1)); fi
			# one count per served REQUEST on busybox and darkhttpd alike (see served_count)
			n=$(( $(served_count) - BASE_LINES ))
			[ "$n" -gt "$TOT_N" ] && n=$TOT_N
			# divide BEFORE multiplying: a full ROM set in KB times a file count overflows 32-bit shell
			# arithmetic, and the bar would jump to garbage
			DONE_N=$n; [ "$TOT_N" -gt 0 ] && DONE_KB=$(( TOT_KB / TOT_N * n ))
			if [ -n "$BASE_TX" ]; then tx=$(cat "$TXF" 2>/dev/null); case "$tx" in ''|*[!0-9]*) ;; *)
				DONE_KB=$(awk -v a="$BASE_TX" -v b="$tx" -v t="$TOT_KB" 'BEGIN { k = (b - a) / 1024 * 25 / 26; if (k > t) k = t; if (k < 0) k = 0; printf "%d", k }') ;;   # awk: byte counts overflow 32-bit shell math; ~4% is TCP/WiFi framing
			esac; fi
			prog "Syncing with $PEER..."
			stopped && { stop_ui; HALT=1; break; }
			sleep 3; i=$((i+3))
		done
		if [ "$HALT" = 1 ]; then
			if oops "Stopped.

Nothing was half-copied.
Pick Sync again to finish." "SYNC AGAIN"; then STATE=find; continue; else exit 0; fi
		fi
		if [ -z "$PEER_GOT" ]; then
			if oops "Connection lost.

Pick Sync again to finish;
nothing was half-copied." "SYNC AGAIN"; then STATE=find; continue; else exit 0; fi
		fi
		PEER_GOT=${PEER_GOT##*_}
		# Retry the second direction IN PLACE. Going back to FIND here deadlocked both devices: the joiner
		# is parked waiting for _dsync_done and is not listening for a new plan, so the host re-elected,
		# recomputed and waited for an _dsync_applied that would never come, while the joiner waited for a
		# _dsync_done that would never come -- and both stayed pingable, so neither budget tripped
		# (2026-09-18 review). Staging makes a retry cheap: only unverified files come again.
		try=0
		while :; do
			try=$((try+1))
			pull_plan "$PEER_BASE" "$W/plan.me" "Copying from $PEER..."; rc=$?
			[ "$rc" = 0 ] && break
			[ "$rc" = 2 ] && break          # the user stopped: do not retry behind their back
			[ "$try" -ge 3 ] && break
			dbg "sync: pull attempt $try failed, retrying in place"
			sleep 3
		done
		if [ "$rc" != 0 ]; then
			# STATE=sync, NOT find: re-entering sync re-reads the _dsync_applied marker already in our
			# log and goes straight back to the pull, leaving the joiner's wait undisturbed.
			# say what happened: a peer that still answers means some ITEMS failed, not the link
			if [ "$rc" = 2 ]; then MM="Stopped."
			elif ping -c1 -W2 "$PEER_IP" >/dev/null 2>&1; then MM="Could not copy everything."
			else MM="Connection lost."; fi
			if oops "$MM

$PEER is up to date.
Pick Sync again to finish this one." "SYNC AGAIN"; then STATE=sync; continue; else exit 0; fi
		fi
		status_off; status "Syncing with $PEER..."      # B off: nothing here can stop safely
		apply_plan "$W/plan.me" > "$W/got"; arc=$?
		GOT=$(cat "$W/got" 2>/dev/null); [ -n "$GOT" ] || GOT=0
		if [ "$arc" != 0 ]; then
			RESUME_BK="$BK"
			if oops "Could not save everything.

Nothing was lost.
Finish it now?" "FINISH"; then STATE=resume; continue; else exit 0; fi
		fi
		# "skipped" = games in systems the user set to Skip, nothing else. Differences a category toggle
		# leaves alone are not skips, and counting them said "565 item(s) skipped" for a two-save sync
		# with Games off on both (Dan, 2026-09-22).
		NSKIP=${NDROP:-0}
		DONE_TEXT=$(done_text "$GOT" "$PEER_GOT" "$NSKIP" "$ANAME" "$BNAME")
		# Publish the COUNTS, never the finished sentence: ANAME/BNAME carry "(this one)"/"(other)", so a
		# line rendered here read backwards on the joiner whenever both devices are the same model.
		printf '%s %s %s\n' "$GOT" "$PEER_GOT" "$NSKIP" > "$SERVE/_dsync_done"
		# hold the AP up briefly so the joiner can read it before we tear the radio down
		smsg "Syncing with $PEER..."
		i=0; while [ "$i" -lt 30 ] && ! grep -q "_dsync_done" /tmp/dsync-httpd.log 2>/dev/null; do sleep 1; i=$((i+1)); done
	fi
	STATE=done ;;

done)
	# Only a COMPLETE journal means every file landed. Clearing the resume pointer and the staged bytes
	# after a partial apply throws away the one thing that could finish it -- and the engine's whole
	# crash-safe journal/resume mechanism with it (2026-09-18 review).
	OKDONE=1
	if [ -n "$BK" ] && [ -d "$BK" ]; then
		case "$(eng journal-status "$BK" 2>/dev/null)" in COMPLETE*) : ;; *) OKDONE=0 ;; esac
	fi
	# BK empty = this device applied nothing this run, so an earlier interrupted apply is NOT ours
	# to clear -- wiping it would throw away a resume the engine deliberately kept retryable
	if [ "$OKDONE" = 1 ] && [ -n "$BK" ]; then
		rm -f "$RES_BK" "$RES_PLAN"        # the apply finished, so there is nothing to resume
		rm -rf "$STAGE"; mkdir -p "$STAGE" # staged copies are applied; free the card
	fi
	dbg "done got=$GOT complete=$OKDONE"
	if [ "$OKDONE" = 0 ]; then
		RESUME_BK="$BK"
		if oops "Could not save everything.

Nothing was lost.
Finish it now?" "FINISH"; then STATE=resume; continue; else exit 0; fi
	fi
	# The summary STAYS until a button (Dan, 2026-09-21: the 3 s auto-dismiss flashed past); only then
	# does teardown reconnect WiFi and return to Tools.
	[ -n "$DONE_TEXT" ] || DONE_TEXT="Synced!

$GOT item(s) copied to
this device."
	tell "$DONE_TEXT"
	exit 0 ;;

resume)
	# power loss during apply. Everything was already staged (the apply only starts once a whole
	# direction is downloaded), so this finishes locally -- no radio, no peer.
	status "Finishing the interrupted sync..."
	write_sysmap; eng resume-apply "$RES_PLAN" "$STAGE" "$LOCAL" "$RESUME_BK" >> "$LOGF" 2>&1
	case "$(eng journal-status "$RESUME_BK" 2>/dev/null)" in
		COMPLETE*) n=$(awk -F"$TAB" '$1=="DONE" && $2!="keep" {n++} END{print n+0}' "$RESUME_BK/journal.log" 2>/dev/null)
		           rm -f "$RES_BK" "$RES_PLAN"; rm -rf "$STAGE"; mkdir -p "$STAGE"
		           tell "Finished.

$n item(s) copied."; exit 0 ;;
		*)         if oops "Could not finish.

Nothing was lost.
Try again?"; then continue; else exit 0; fi ;;
	esac ;;

restore)
	# a LOCAL restore, not a synced undo: it puts this device back and backs up the current files first,
	# so the restore is itself undoable and nothing is ever destroyed.
	set --; i=0; : > "$W/bmap"
	for b in $(ls -1 "$BK_ROOT" 2>/dev/null | sort -r | head -5); do
		i=$((i+1)); printf 'b%s\t%s\n' "$i" "$b" >> "$W/bmap"
		lbl=$(cat "$BK_ROOT/$b/label" 2>/dev/null); [ -n "$lbl" ] || lbl="$b"
		# count ops.log, not the journal: it is one line per file actually changed and it is also what
		# the older (v1) backups on a card already carry, so they stay restorable from this screen
		n=$(awk 'END{print NR+0}' "$BK_ROOT/$b/ops.log" 2>/dev/null)
		set -- "$@" "b$i" "$lbl" "" "$n item(s)" "Put these $n file(s) back."
	done
	if [ "$i" = 0 ]; then tell "No backups yet."; STATE=entry; continue; fi
	menu --title "Restore backup" "$@" > "$W/out"
	OPEN=$(sed -n 's/^OPEN=//p' "$W/out" | head -1)
	case "$OPEN" in
		b*) b=$(awk -F"$TAB" -v k="$OPEN" '$1==k{print $2; exit}' "$W/bmap")
		    # the files of that sync, one row per game/list, each Keep: A marks a row Restore, X restores the
		    # marked rows (nothing marked = offer all of them), B goes back to the list (Dan, 2026-09-22)
		    restore_rows "$BK_ROOT/$b/ops.log" > "$W/rrows"
		    set --; ri=0; : > "$W/rmap"
		    while IFS="$TAB" read -r ro rn rt rr; do
			k=$(awk -F"$TAB" -v n="$rn" -v t="$rt" '$2==n && $3==t {print $1; exit}' "$W/rmap")
			if [ -z "$k" ]; then ri=$((ri+1)); k="r$ri"; set -- "$@" "$k" "$rn" "Keep|Restore" "Keep" "$rt"; fi
			printf '%s\t%s\t%s\t%s\n' "$k" "$rn" "$rt" "$rr" >> "$W/rmap"
		    done < "$W/rrows"
		    [ "$ri" -gt 0 ] || { tell "Nothing to restore in this backup."; STATE=restore; continue; }
		    lbl=$(cat "$BK_ROOT/$b/label" 2>/dev/null); [ -n "$lbl" ] || lbl="$b"
		    menu --wide --title "Restore: $lbl" --x-label "Restore" "$@" > "$W/out"
		    grep -q '^ACTION=x$' "$W/out" || { STATE=restore; continue; }
		    : > "$W/rsel"
		    for k in $(sed -n 's/=Restore$//p' "$W/out" | grep '^r[0-9]*$'); do awk -F"$TAB" -v k="$k" '$1==k {print $4}' "$W/rmap" >> "$W/rsel"; done
		    NR_SEL=$(awk 'END{print NR+0}' "$W/rsel"); NR_ALL=$(awk 'END{print NR+0}' "$W/rrows")
		    if [ "$NR_SEL" -eq 0 ]; then
			ask "Restore all $NR_ALL file(s)
from before that sync?

Current files are backed
up first." "RESTORE ALL" "BACK" || { STATE=restore; continue; }
			rm -f "$W/rsel"
		    else
			ask "Restore $NR_SEL file(s)?

Current files are backed
up first." "RESTORE" "BACK" || { STATE=restore; continue; }
		    fi
		    status "Restoring..."; write_sysmap
		    # restore() skips a file it cannot put back (a pruned backup, a full card, a bad sector) and
		    # returns 1, saying so only in the log. "Restored." on top of that is the worst lie this pak
		    # can tell: the user plays on believing their pre-sync saves are back (2026-09-18 review).
		    # restore prints the NEW snapshot dir first (the files as they were just before this restore):
		    # label it, so "go back to the synced state" is a readable row in this same list
		    if [ -s "$W/rsel" ]; then NEWBK=$(eng restore "$LOCAL" "$BK_ROOT/$b" "$W/rsel" 2>> "$LOGF" | head -1); rrc=$?
		    else NEWBK=$(eng restore "$LOCAL" "$BK_ROOT/$b" 2>> "$LOGF" | head -1); rrc=$?; fi
		    [ -d "$NEWBK" ] && printf 'Before restore, %s' "$(date '+%b %d %H:%M' 2>/dev/null)" > "$NEWBK/label" 2>/dev/null
		    rrc=$(if [ -f "$NEWBK/journal.log" ] && [ "$(eng journal-status "$NEWBK" 2>/dev/null)" = COMPLETE ]; then echo 0; else echo 1; fi)
		    if [ "$rrc" = 0 ]; then
			    tell "Restored.

What was on the card first
was backed up, not lost."; exit 0
		    fi
		    if oops "Could not put everything back.

Nothing was deleted.
Try again?"; then continue; else exit 0; fi ;;
		*)  STATE=entry ;;
	esac ;;

*) exit 0 ;;
esac
done
