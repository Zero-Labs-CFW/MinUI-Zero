#!/bin/sh
# Sync the built .system payload to the Miyoo Mini Plus over SSH.
#
#   sh tools/deploy-miyoomini.sh [user@host[:port]]
#
# Defaults to root@192.168.1.10. Run from the repo root AFTER a successful
#   make PLATFORMS=miyoomini miyoomini
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

TARGET=${1:-root@192.168.1.10}
PORT=22
case "$TARGET" in
	*:*) PORT=${TARGET##*:}; TARGET=${TARGET%:*} ;;
esac

SRC=./build/PAYLOAD/.system/miyoomini
DST=/mnt/SDCARD/.system/miyoomini

[ -d "$SRC" ] || { echo "no build payload at $SRC — run: make PLATFORMS=miyoomini miyoomini"; exit 1; }
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
	echo "rebuild first: make PLATFORMS=miyoomini miyoomini"
	exit 1
}

SSH="ssh -p $PORT -o ConnectTimeout=8"

echo "target : $TARGET:$PORT"
echo "build  : $(cat ./build/latest.txt)"

$SSH "$TARGET" true 2>/dev/null || {
	echo "device unreachable at $TARGET:$PORT"
	echo "  - power it on; run Tools > SSH once per boot (it insmods the wifi module)"
	echo "  - after a reboot it takes ~2 minutes to reassociate; poll ssh, not ping"
	exit 1
}

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

# .system/res first: the shared root (zero-log.sh, which MinUI.pak/launch.sh sources, the sprite sheets, the font).
# Upload-only by md5, never pruned: it is shared, not this platform's directory.
RSRC=./build/PAYLOAD/.system/res
RDST=/mnt/SDCARD/.system/res
if [ -d "$RSRC" ]; then
	for f in "$RSRC"/*; do
		[ -f "$f" ] || continue
		n=$(basename "$f")
		want=$(md5 -q "$f" 2>/dev/null || md5sum "$f" | cut -d' ' -f1)
		have=$($SSH "$TARGET" "md5sum '$RDST/$n' 2>/dev/null | cut -d' ' -f1" 2>/dev/null || true)
		[ "$want" = "$have" ] && continue
		echo "  -> .system/res/$n"
		$SSH "$TARGET" "mkdir -p '$RDST' && cat > '$RDST/$n.new' && mv -f '$RDST/$n.new' '$RDST/$n'" < "$f"
	done
fi

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
if [ "$N" -eq 0 ]; then
	echo "nothing to do — device already matches this build"
	exit 0
fi

echo "--- deploying ---"
while IFS= read -r f; do
	echo "  -> $f"
	# Stage then mv: minui.elf/minarch.elf may be RUNNING, and writing over a live binary is
	# ETXTBSY. mv within one filesystem is atomic, so a yanked battery leaves old or new, never half.
	$SSH "$TARGET" "mkdir -p '$DST/$(dirname "$f")' && cat > '$DST/$f.new' && chmod 755 '$DST/$f.new' && mv -f '$DST/$f.new' '$DST/$f'" < "$SRC/$f"
done < "$CHANGED"

# Remove remote files the build no longer produces. Without this the "sync" is upload-only, so a
# deleted pak or renamed core lingers on the card and quietly contaminates the next device test
# (exactly the stale-pairing class that cost an evening on the MINARCH_PRELOAD audio break).
# Scoped strictly to $DST, which is OUR payload directory — user data lives elsewhere on the card.
cut -d' ' -f3- "$WORK/local.txt" | sed 's/^ *//' | sort > "$WORK/local-paths.txt"
cut -d' ' -f3- "$WORK/remote.txt" 2>/dev/null | sed 's/^ *//' | sort > "$WORK/remote-paths.txt"
STALE=$(comm -13 "$WORK/local-paths.txt" "$WORK/remote-paths.txt")
if [ -n "$STALE" ]; then
	echo "--- removing stale ---"
	echo "$STALE" | while IFS= read -r f; do
		[ -n "$f" ] || continue
		echo "  xx $f"
		$SSH "$TARGET" "rm -f '$DST/$f'"
	done
fi

# Flush to the card before anything can power-cycle it. FAT32 + a yanked battery loses the write.
$SSH "$TARGET" "sync"

echo "--- verifying ---"
$SSH "$TARGET" "$REMOTE_MANIFEST" 2>/dev/null > "$WORK/after.txt"
BAD=0
while IFS= read -r line; do
	grep -qxF "$line" "$WORK/after.txt" || { echo "  FAIL ${line#*  }"; BAD=1; }
done < "$WORK/local.txt"
if [ "$BAD" -ne 0 ]; then exit 1; fi
echo "  ok   all $TOTAL files match the build"

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
