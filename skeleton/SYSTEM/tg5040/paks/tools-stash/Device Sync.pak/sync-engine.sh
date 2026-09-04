#!/bin/sh
# Device Sync -- transport-blind sync engine.
#
# NO radios, NO network, NO UI. Operates on two local directories and nothing else, so it is
# fully testable on the macOS dummy platform (see .notes/2026-09-03-device-sync/test-engine.sh).
# The pak's launch.sh layers UI (confirm.elf/say.elf) and transport (SoftAP) on top of this.
#
# Model: a DIRECTIONAL reconcile. "src" is the incoming tree (from the peer on receive), "dst" is
# the local tree. reconcile brings src's missing/newer files INTO dst. Two-way sync = both devices
# reconcile with the other as src. The engine only ever writes to dst.
#
# HARD SAFETY GUARANTEES (this is the whole point -- must be incapable of losing a save):
#   1. Never overwrite in place. Write to <file>.dsync.tmp, verify size, then atomic mv over target.
#      A power loss mid-write leaves the tmp and the original intact, never a truncated save.
#   2. Always back up before replacing. An UPDATE copies dst's current file into the backup dir
#      BEFORE overwriting. ops.log records every ADD/UPDATE so "undo" restores the exact pre-sync
#      state (ADDs removed, UPDATEs restored).
#   3. Never delete. A file that exists only in dst is never touched. Absence in src is not a signal.
#
# CLOCK CAVEAT: these devices can carry a wrong RTC/timezone (see the clock saga), so "newer mtime"
# is advisory. Identical files (hash match) are skipped untouched; when files genuinely differ, the
# newer wins BUT the loser on the dst side is always backed up, so a wrong clock can never lose data.
#
# TODO(verify on-device): confirm the real on-card save/state/cfg paths before shipping. The
# classify() prefixes below (Roms/, Saves/, Collections/, *.cfg, map.txt) are the assumed layout.

TAB=$(printf '\t')

# ---- portable shims: busybox (device) and BSD (macOS dev) ----
file_size()  { [ -e "$1" ] && wc -c < "$1" | tr -d ' ' || echo 0; }
file_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }
file_hash()  {
	if   command -v md5sum >/dev/null 2>&1; then md5sum "$1" 2>/dev/null | cut -d' ' -f1
	elif command -v md5    >/dev/null 2>&1; then md5 -q "$1" 2>/dev/null
	else echo "nohash-$(file_size "$1")"; fi
}

# ---- classification: relpath -> class, class -> merge rule ----
classify() {
	case "$1" in
		Roms/*)              echo rom ;;
		Saves/*)             echo save ;;
		Collections/*)       echo collection ;;
		map.txt|*/map.txt)   echo map ;;
		*.cfg)               echo config ;;
		*)                   echo other ;;
	esac
}
rule_for() { # rom = additive (never overwrite); everything else = newer-wins + backup
	case "$1" in rom) echo additive ;; *) echo newer ;; esac
}

# ---- manifest: relpath \t size \t mtime \t class, one line per file ----
manifest() {
	d="$1"
	( cd "$d" 2>/dev/null || exit 0
	  find . -type f 2>/dev/null | sed 's|^\./||' | while IFS= read -r rel; do
		[ -n "$rel" ] || continue
		printf '%s\t%s\t%s\t%s\n' "$rel" "$(file_size "$rel")" "$(file_mtime "$rel")" "$(classify "$rel")"
	  done )
}

# ---- plan: compare src against dst, emit one ACTION\trelpath per src file ----
# Actions: ADD UPDATE SKIP KEEP-LOCAL CONFLICT-ROM. dst-only files never appear (never deleted).
plan() {
	src="$1"; dst="$2"
	manifest "$src" | while IFS="$TAB" read -r rel size mtime class; do
		rule=$(rule_for "$class")
		if [ ! -e "$dst/$rel" ]; then
			printf 'ADD\t%s\n' "$rel"
		elif [ "$rule" = additive ]; then
			if [ "$size" = "$(file_size "$dst/$rel")" ]; then
				printf 'SKIP\t%s\n' "$rel"          # same ROM, leave it
			else
				printf 'CONFLICT-ROM\t%s\n' "$rel"  # different dump; keep local, never overwrite a ROM
			fi
		else
			if [ "$size" = "$(file_size "$dst/$rel")" ] && \
			   [ "$(file_hash "$src/$rel")" = "$(file_hash "$dst/$rel")" ]; then
				printf 'SKIP\t%s\n' "$rel"          # byte-identical
			else
				dmtime=$(file_mtime "$dst/$rel")
				if [ "${mtime:-0}" -gt "${dmtime:-0}" ]; then
					printf 'UPDATE\t%s\n' "$rel"    # src newer: overwrite (after backing up dst)
				else
					printf 'KEEP-LOCAL\t%s\n' "$rel" # dst newer-or-equal: keep local, nothing lost
				fi
			fi
		fi
	done
}

# ---- apply: execute the plan with atomic writes, pre-overwrite backup, never-delete ----
apply() {
	src="$1"; dst="$2"; bdir="$3"
	mkdir -p "$bdir"
	: > "$bdir/ops.log"
	plan "$src" "$dst" | while IFS="$TAB" read -r action rel; do
		case "$action" in
		ADD)
			mkdir -p "$dst/$(dirname "$rel")"
			cp "$src/$rel" "$dst/$rel.dsync.tmp" 2>/dev/null
			if [ "$(file_size "$src/$rel")" = "$(file_size "$dst/$rel.dsync.tmp")" ]; then
				mv "$dst/$rel.dsync.tmp" "$dst/$rel"
				printf 'ADD\t%s\n' "$rel" >> "$bdir/ops.log"
			else
				rm -f "$dst/$rel.dsync.tmp"; printf 'FAIL\t%s\n' "$rel" >&2
			fi ;;
		UPDATE)
			mkdir -p "$bdir/$(dirname "$rel")"
			cp "$dst/$rel" "$bdir/$rel"                 # BACK UP the loser first
			cp "$src/$rel" "$dst/$rel.dsync.tmp" 2>/dev/null
			if [ "$(file_size "$src/$rel")" = "$(file_size "$dst/$rel.dsync.tmp")" ]; then
				mv "$dst/$rel.dsync.tmp" "$dst/$rel"
				printf 'UPDATE\t%s\n' "$rel" >> "$bdir/ops.log"
			else
				rm -f "$dst/$rel.dsync.tmp"; printf 'FAIL\t%s\n' "$rel" >&2
			fi ;;
		*) : ;;  # SKIP / KEEP-LOCAL / CONFLICT-ROM: no write, nothing lost
		esac
	done
}

# ---- undo: restore the exact pre-sync state from a backup dir's ops.log ----
undo() {
	dst="$1"; bdir="$2"
	[ -f "$bdir/ops.log" ] || { echo "undo: no ops.log in $bdir" >&2; return 1; }
	while IFS="$TAB" read -r action rel; do
		case "$action" in
			ADD)    # was new: remove the file, then any now-empty dirs the ADD created
				rm -f "$dst/$rel"
				d=$(dirname "$rel")
				while [ "$d" != "." ] && [ "$d" != "/" ]; do
					rmdir "$dst/$d" 2>/dev/null || break   # stops at the first non-empty dir; never touches dst
					d=$(dirname "$d")
				done ;;
			UPDATE) cp "$bdir/$rel" "$dst/$rel" ;;      # was overwritten: restore original
		esac
	done < "$bdir/ops.log"
}

# ---- prune: keep the newest N backup snapshots under a root (timestamp-named dirs) ----
prune() {
	root="$1"; keep="$2"
	n=$(ls -1 "$root" 2>/dev/null | wc -l | tr -d ' ')
	[ "$n" -gt "$keep" ] 2>/dev/null || return 0
	rmn=$((n - keep))
	ls -1 "$root" | sort | head -n "$rmn" | while IFS= read -r old; do rm -rf "$root/$old"; done
}

# ---- CLI dispatch (used by tests and by launch.sh) ----
cmd="$1"; [ $# -gt 0 ] && shift
case "$cmd" in
	manifest) manifest "$@" ;;
	plan)     plan "$@" ;;
	apply)    apply "$@" ;;
	undo)     undo "$@" ;;
	prune)    prune "$@" ;;
	classify) classify "$@" ;;
	*) echo "usage: sync-engine.sh {manifest|plan|apply|undo|prune|classify} ..." >&2; exit 2 ;;
esac
