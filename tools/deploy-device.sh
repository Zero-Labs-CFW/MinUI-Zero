#!/bin/sh
# Sync a built .system payload to a device over SSH.
#
#   sh tools/deploy-device.sh <platform> [user@host[:port]] [-i identity]
#
#   sh tools/deploy-device.sh miyoomini root@192.168.1.10
#   sh tools/deploy-device.sh tg5040    root@192.168.1.90 -i ~/.ssh/tg5040_dev
#
# Run from the repo root AFTER a successful `make PLATFORMS=<platform> <platform>`.
#
# WHY THIS SYNCS THE WHOLE TREE, not a hand-picked file list.
# An earlier version copied four files (minarch.elf, minui.elf, MinUI.pak/launch.sh, one core).
# That is unsound whenever a change spans files, and it bit immediately: MinUI.pak/launch.sh was
# updated to hand the audio shim to minarch via MINARCH_PRELOAD instead of exporting LD_PRELOAD,
# but the eight Emus/*/launch.sh that CONSUME MINARCH_PRELOAD were not in the list. The device ran
# a new MinUI.pak against stale emu paks, so the shim never reached minarch, SDL picked the `dsp`
# driver, /dev/dsp could not be opened without libpadsp, and every game lost audio. The repo was
# correct the whole time; only the deploy was partial.
#
# So: compare md5 of every file and send whatever differs. First run is slow (~48MB), later runs
# send only what changed.
#
# NOT scp. The MMP firmware ships neither /usr/libexec/sftp-server (so modern scp, which speaks
# SFTP by default, dies "Connection closed") nor an scp binary (so `scp -O`, the legacy-protocol
# fallback, dies "scp: not found"). Piping through the shell needs only cat, which busybox has.
set -e

PLATFORM=${1:?usage: deploy-device.sh <platform> [user@host[:port]] [-i identity] [--delete]}
TARGET=${2:-root@192.168.1.10}
IDENT=""
DELETE_STALE=0
for arg in "$@"; do [ "$arg" = "--delete" ] && DELETE_STALE=1; done
if [ "${3:-}" = "-i" ] && [ -n "${4:-}" ]; then IDENT="-i $4"; fi
PORT=22
case "$TARGET" in
	*:*) PORT=${TARGET##*:}; TARGET=${TARGET%:*} ;;
esac

# TWO PAYLOAD ROOTS, not one. `make <platform>` stages BOTH build/PAYLOAD/.system/<platform> and
# build/PAYLOAD/Tools/<platform>, which land on the card at /mnt/SDCARD/.system/<platform> and
# /mnt/SDCARD/Tools/<platform>. Syncing only the first is the same partial-deploy bug this script
# was written to prevent, and it bit exactly that way on 2026-08-30: the Tools paks draw their UI
# with their OWN binaries (Clock.pak/clock.elf, Input.pak/minput.elf, plus the confirm.elf and
# say.elf the others call), all of which compute geometry from platform.h. A Brick Pro therefore
# kept rendering Tools at Smart Pro size after a "successful" deploy that reported a full match,
# because the entire Tools half of the payload was never examined. Worse, MinUI.pak/launch.sh
# re-arms the undervolt harness from Tools/ at every boot, so the consumer updated while the
# producer did not. Sync every root or the "whole-tree" guarantee in the header above is a lie.
SRC=./build/PAYLOAD/.system/$PLATFORM
DST=/mnt/SDCARD/.system/$PLATFORM
SRC2=./build/PAYLOAD/Tools/$PLATFORM
DST2=/mnt/SDCARD/Tools/$PLATFORM
# .tmp_update is the BOOT DISPATCH (tg5040.sh, updater, the boot artwork). It is not per-platform:
# the staged directory is shared, and it is what runs before the launcher on every boot. Omitting
# it meant a change to install/boot.sh could never reach a device, which is precisely how the
# LED-timing fix appeared to do nothing after a "successful" deploy (2026-08-30). Third root.
SRC3=./build/PAYLOAD/.tmp_update
DST3=/mnt/SDCARD/.tmp_update
# .system/res is the SHARED asset root -- the sprite sheets, the font, the grid/line art. It sits
# beside .system/<platform>, not inside it, so the per-platform root above walks straight past it.
# That was invisible while the sheets never changed; the Brick Pro's assets@2.5x.png broke the
# assumption, and a binary that selects a sheet its card does not carry does not degrade, it
# segfaults (api.c calls IMG_Load then hands the result to SDLX_SetAlpha). Fourth root.
SRC4=./build/PAYLOAD/.system/res
DST4=/mnt/SDCARD/.system/res

[ -d "$SRC" ] || { echo "no build payload at $SRC — run: make PLATFORMS=$PLATFORM $PLATFORM"; exit 1; }
[ -f ./build/latest.txt ] || { echo "no build/latest.txt — build did not complete"; exit 1; }

# Refuse to deploy a build older than the working tree. A deploy that silently ships yesterday's
# binaries is worse than no deploy: the device test then certifies the wrong code.
# Watch EVERY input that can change the payload, not just sources: cfgs, makefiles, core patches and
# shipped assets all alter what gets built, and an earlier version of this gate watched only
# .c/.h/launch.sh so a changed default.cfg could deploy from a stale build.
NEWER=$(find workspace skeleton -newer ./build/latest.txt -type f \
	! -path '*/cores/src/*' ! -name '*.o' ! -name '*.d' -print -quit 2>/dev/null || true)
[ -z "$NEWER" ] || {
	echo "STALE BUILD: $NEWER is newer than build/latest.txt"
	echo "rebuild first: make PLATFORMS=$PLATFORM $PLATFORM"
	exit 1
}

# Host keys: these are OUR dev handhelds on a LAN, and their key changes every time a card is
# reflashed or a fresh dropbear host key is generated. With the defaults, ssh refuses a host it has
# never seen ("Host key verification failed") and a NON-INTERACTIVE deploy simply dies, which is
# exactly what happened deploying to the Brick Pro on 2026-08-30 while a plain ssh with these two
# options connected fine. accept-new is not enough either: it still rejects a CHANGED key, which is
# the normal case after a reflash. Same reasoning, and the same two options, as the h700 dev
# wrapper. Do not copy this pattern to anything reachable off the LAN.
SSH="ssh -p $PORT -o ConnectTimeout=8 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR $IDENT"

echo "target : $TARGET:$PORT  ($PLATFORM)"
echo "build  : $(cat ./build/latest.txt)"

$SSH "$TARGET" true 2>/dev/null || {
	echo "device unreachable at $TARGET:$PORT"
	# There is NO "Tools > SSH" pak on this platform — this line used to claim there was, which sent
	# a later session hunting for a tool that has never existed (Dan, 2026-09-08: "not true").
	# SSH here comes from .system/$PLATFORM/bin/dev-net.sh, which MinUI.pak/launch.sh starts at boot
	# ONLY when .userdata/shared/enable-ssh is present. So the fix is a file on the card, not a menu.
	echo "  - power it on; SSH starts at boot only if .userdata/shared/enable-ssh exists on the card"
	echo "    (dev-net.sh writes the address it got to .userdata/shared/ssh-ip.txt)"
	echo "  - after a reboot it takes ~2 minutes to reassociate; poll ssh, not ping"
	exit 1
}

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
GRAND_TOTAL=0
GRAND_SENT=0

# sync_root <src> <dst> <label>
sync_root() {
SRC=$1; DST=$2; LABEL=$3
if [ ! -d "$SRC" ]; then
	# A platform without curated Tools is legitimate; say so rather than silently skipping.
	echo "--- $LABEL: no staged payload at $SRC, skipping"
	return 0
fi
echo "--- $LABEL: $SRC -> $DST"

REMOTE_MANIFEST="cd $DST 2>/dev/null && find . -type f | sed 's|^\./||' | sort | while IFS= read -r f; do echo \"\$(md5sum \"\$f\" | cut -d' ' -f1)  \$f\"; done"

# Local manifest: "<md5>  <path relative to SRC>"
( cd "$SRC" && find . -type f | sed 's|^\./||' | sort | while IFS= read -r f; do
	echo "$( (md5 -q "$f" 2>/dev/null || md5sum "$f" | cut -d' ' -f1) )  $f"
done ) > "$WORK/local.txt"

$SSH "$TARGET" "$REMOTE_MANIFEST" 2>/dev/null > "$WORK/remote.txt" || true

# Anything whose (md5, path) pair is absent remotely needs sending.
CHANGED="$WORK/changed.txt"
: > "$CHANGED"
while IFS= read -r line; do
	grep -qxF "$line" "$WORK/remote.txt" || echo "${line#*  }" >> "$CHANGED"
done < "$WORK/local.txt"

N=$(wc -l < "$CHANGED" | tr -d ' ')
TOTAL=$(wc -l < "$WORK/local.txt" | tr -d ' ')
echo "files  : $N of $TOTAL differ"
GRAND_TOTAL=$((GRAND_TOTAL + TOTAL))
GRAND_SENT=$((GRAND_SENT + N))
if [ "$N" -eq 0 ]; then
	echo "  nothing to do for $LABEL"
	return 0
fi

echo "--- deploying ---"
while IFS= read -r f; do
	echo "  -> $f"
	# Stage then mv: minui.elf/minarch.elf may be RUNNING, and writing over a live binary is
	# ETXTBSY. mv within one filesystem is atomic, so a yanked battery leaves old or new, never half.
	$SSH "$TARGET" "mkdir -p '$DST/$(dirname "$f")' && cat > '$DST/$f.new' && chmod 755 '$DST/$f.new' && mv -f '$DST/$f.new' '$DST/$f'" < "$SRC/$f"
done < "$CHANGED"

# Remove remote files the build no longer produces — OPT-IN via --delete. Without deletion the
# "sync" is upload-only, so a deleted pak or renamed core lingers and can contaminate the next
# device test (the stale-pairing class that cost an evening on the MINARCH_PRELOAD audio break).
# But $DST on a DAILY-DRIVER card legitimately holds files the build never produced — Dan's Brick
# carries a dozen minarch.elf.* backups and unshipped libraries — and an unconditional pass here
# would have deleted all of them (previewed 2026-08-01: 63 files; never run). Default is therefore
# KEEP; pass --delete on cards we own outright (the MMP test card).
cut -d' ' -f3- "$WORK/local.txt" | sed 's/^ *//' | sort > "$WORK/local-paths.txt"
cut -d' ' -f3- "$WORK/remote.txt" 2>/dev/null | sed 's/^ *//' | sort > "$WORK/remote-paths.txt"
STALE=$(comm -13 "$WORK/local-paths.txt" "$WORK/remote-paths.txt")
if [ -n "$STALE" ]; then
	if [ "$DELETE_STALE" = "1" ]; then
		echo "--- removing stale ---"
		echo "$STALE" | while IFS= read -r f; do
			[ -n "$f" ] || continue
			echo "  xx $f"
			$SSH "$TARGET" "rm -f '$DST/$f'"
		done
	else
		echo "--- stale files on device KEPT (pass --delete to remove) ---"
		echo "$STALE" | head -5 | sed 's/^/  keep /'
		N=$(echo "$STALE" | wc -l | tr -d ' ')
		[ "$N" -gt 5 ] && echo "  ... and $((N-5)) more"
	fi
fi

# Flush to the card before anything can power-cycle it. FAT32 + a yanked battery loses the write.
$SSH "$TARGET" "sync"

echo "--- verifying ---"
$SSH "$TARGET" "$REMOTE_MANIFEST" 2>/dev/null > "$WORK/after.txt"
BAD=0
while IFS= read -r line; do
	grep -qxF "$line" "$WORK/after.txt" || { echo "  FAIL ${line#*  }"; BAD=1; }
done < "$WORK/local.txt"
if [ "$BAD" -ne 0 ]; then return 1; fi
echo "  ok   $LABEL: all $TOTAL files match the build"
return 0
}

# Every staged root, in order. .system is required; Tools is skipped when a platform ships none.
# Report the UNION at the end: a per-root "nothing to do" printed alone is the same false green
# that let the Tools half go unexamined for a whole day.
sync_root "$SRC"  "$DST"  ".system"     || exit 1
sync_root "$SRC2" "$DST2" "Tools"       || exit 1
sync_root "$SRC3" "$DST3" ".tmp_update" || exit 1
sync_root "$SRC4" "$DST4" ".system/res" || exit 1
# version.txt (and commits.txt) live at the .system ROOT, in none of the four synced roots -- the
# same blind-spot class as .system/res. Left unsynced, a dev card reports the version of whatever
# zip it was FIRST installed from forever (this one said v1.5.5 through twelve deploys of v1.6.1).
for VF in version.txt commits.txt; do
	[ -f "./build/PAYLOAD/.system/$VF" ] || continue
	if ! $SSH "$TARGET" "md5sum /mnt/SDCARD/.system/$VF 2>/dev/null" | grep -q "$(md5 -q "./build/PAYLOAD/.system/$VF" 2>/dev/null || md5sum "./build/PAYLOAD/.system/$VF" | cut -d" " -f1)"; then
		$SSH "$TARGET" "cat > /mnt/SDCARD/.system/$VF" < "./build/PAYLOAD/.system/$VF" && echo "  sent .system/$VF ($(head -1 "./build/PAYLOAD/.system/$VF"))"
	fi
done

if [ "$GRAND_SENT" -eq 0 ]; then
	echo "nothing to do — device already matches this build ($GRAND_TOTAL files across all roots)"
else
	echo "deployed $GRAND_SENT of $GRAND_TOTAL files across all payload roots"
fi

cat <<EOF

deployed $(cat ./build/latest.txt)

TWO DIFFERENT RESTARTS — they do not pick up the same things.

  $SSH $TARGET 'kill -9 \$(pidof minui.elf)'
      Picks up minui.elf, minarch.elf, the cores, and every Emus/*/launch.sh (those are read
      fresh on each game launch). This only makes MinUI.pak/launch.sh ITERATE its menu loop;
      everything above the loop, including audio_daemon_start and the boot-path daemon release,
      does NOT re-run. The running shell also still holds the OLD MinUI.pak/launch.sh inode,
      because this script installs via mv.
      MUST be SIGKILL by pid: 'killall minui.elf' and plain TERM are PROVEN no-ops on this
      firmware (the vendor SDL2 catches SIGTERM and posts SDL_QUIT, which minui ignores).

  full power cycle
      The ONLY way to exercise a MinUI.pak/launch.sh change or anything about daemon startup
      ordering. The daemon can only win MI_AO at boot, before the menu opens the codec, so daemon
      behaviour is simply not testable without one.
EOF
