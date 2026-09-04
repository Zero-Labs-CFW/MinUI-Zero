#!/bin/sh
# Device Sync -- transport-blind sync engine.
#
# NO radios, NO network, NO UI. Operates on local directories + a manifest, so it is fully testable
# on the host (see workspace/all/common/run-devicesync-tests.sh). The pak's launch.sh layers UI
# (confirm.elf/say.elf) and transport (SoftAP + httpd/wget, see sync-net.sh) on top of this.
#
# TWO MODES, one core:
#   dir-to-dir  (host tests): src dir holds both the manifest and the bytes.
#   networked   (on device):  the receiver has the sender's MANIFEST (fetched over HTTP) plus the
#               downloaded delta bytes in a STAGING dir. wget does not preserve mtime, so the
#               manifest's mtime is authoritative for the merge decision AND is stamped onto the
#               applied file -- otherwise every freshly-downloaded file looks "newer" than local.
#
# HARD SAFETY GUARANTEES (must be incapable of losing a save):
#   1. Never overwrite in place. Write <file>.dsync.tmp, verify size, atomic mv. Power loss mid-write
#      leaves the tmp + original intact, never a truncated save.
#   2. Always back up before replacing. UPDATE copies dst's current file into the backup dir first.
#      ops.log records every ADD/UPDATE so undo restores the EXACT pre-sync state.
#   3. Never delete. A file only in dst is never touched; absence in the manifest is not a signal.
#
# CLOCK CAVEAT: devices can carry a wrong RTC/timezone, so "newer mtime" is advisory. Identical files
# (size+hash match) are skipped untouched; when files genuinely differ the newer wins BUT the loser
# on the dst side is always backed up, so a wrong clock can never lose data.
#
# MANIFEST format, one line per file: relpath \t size \t mtime(epoch) \t class \t hash
#   hash = md5 for non-ROM; "-" for ROM (immutable + large: size-compare only, don't hash gigabytes).
#
# TODO(verify on-device): confirm the real on-card save/state/cfg paths. classify() prefixes
# (Roms/, Saves/, Collections/, *.cfg, map.txt) are the assumed layout.

TAB=$(printf '\t')

# ---- portable shims: busybox (device) and BSD (macOS dev) ----
file_size()  { [ -e "$1" ] && wc -c < "$1" | tr -d ' ' || echo 0; }
file_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || date -r "$1" +%s 2>/dev/null || echo 0; }  # busybox has no stat; date -r reads a file's mtime there
file_hash()  {
	if   command -v md5sum >/dev/null 2>&1; then md5sum "$1" 2>/dev/null | cut -d' ' -f1
	elif command -v md5    >/dev/null 2>&1; then md5 -q "$1" 2>/dev/null
	else echo "nohash-$(file_size "$1")"; fi
}
fmt_ts()   { date -r "$1" +%Y%m%d%H%M.%S 2>/dev/null || date -d @"$1" +%Y%m%d%H%M.%S 2>/dev/null; }
set_mtime(){ ts=$(fmt_ts "$2"); [ -n "$ts" ] && touch -t "$ts" "$1" 2>/dev/null; }
tmpf()     { mktemp "${TMPDIR:-/tmp}/dsync.XXXXXX"; }

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
rule_for() { case "$1" in rom) echo additive ;; *) echo newer ;; esac; }  # rom never overwritten

# ---- manifest: rel \t size \t mtime \t class \t hash ----
manifest() {
	( cd "$1" 2>/dev/null || exit 0
	  find -L . -type f 2>/dev/null | sed 's|^\./||' | while IFS= read -r rel; do
		[ -n "$rel" ] || continue
		cls=$(classify "$rel")
		if [ "$cls" = rom ]; then h="-"; else h=$(file_hash "$rel"); fi
		printf '%s\t%s\t%s\t%s\t%s\n' "$rel" "$(file_size "$rel")" "$(file_mtime "$rel")" "$cls" "$h"
	  done )
}

# ---- _plan_rich: compare a manifest against dst. Emits ACTION \t MTIME \t REL (internal form) ----
# Actions: ADD UPDATE SKIP KEEP-LOCAL CONFLICT-ROM. dst-only files never appear (never deleted).
_plan_rich() {
	mfile="$1"; dst="$2"
	while IFS="$TAB" read -r rel size mtime class hash; do
		[ -n "$rel" ] || continue
		# reject path traversal / absolute paths from a peer-supplied manifest: every consumer
		# (delta / plan-net / apply-net / dir-to-dir) routes through here, so one guard covers writes,
		# backups and downloads. An unsafe rel could escape dst and the undo/backup safety net.
		case "$rel" in /*|..|../*|*/..|*/../*) printf 'UNSAFE\t%s\n' "$rel" >&2; continue ;; esac
		rule=$(rule_for "$class")
		if [ ! -e "$dst/$rel" ]; then
			printf 'ADD\t%s\t%s\n' "$mtime" "$rel"
		elif [ "$rule" = additive ]; then
			if [ "$size" = "$(file_size "$dst/$rel")" ]; then printf 'SKIP\t%s\t%s\n' "$mtime" "$rel"
			else printf 'CONFLICT-ROM\t%s\t%s\n' "$mtime" "$rel"; fi
		else
			if [ "$size" = "$(file_size "$dst/$rel")" ] && [ "$hash" = "$(file_hash "$dst/$rel")" ]; then
				printf 'SKIP\t%s\t%s\n' "$mtime" "$rel"
			else
				dmtime=$(file_mtime "$dst/$rel")
				if [ "${mtime:-0}" -gt "${dmtime:-0}" ]; then printf 'UPDATE\t%s\t%s\n' "$mtime" "$rel"
				else printf 'KEEP-LOCAL\t%s\t%s\n' "$mtime" "$rel"; fi
			fi
		fi
	done < "$mfile"
}

# ---- _apply_rich: execute a manifest's plan, pulling bytes from a staging dir ----
# Atomic writes, pre-overwrite backup, never-delete, mtime stamped from the manifest.
_apply_rich() {
	mfile="$1"; staging="$2"; dst="$3"; bdir="$4"
	# fail closed on a reused backup dir: clobbering a prior snapshot's ops.log would strand its undo
	if [ -e "$bdir/ops.log" ]; then
		echo "apply: backup dir already used ($bdir); refusing to clobber a prior snapshot" >&2; return 1
	fi
	mkdir -p "$bdir"; : > "$bdir/ops.log"
	_plan_rich "$mfile" "$dst" | while IFS="$TAB" read -r action mtime rel; do
		case "$action" in
		ADD|UPDATE)
			[ -e "$staging/$rel" ] || { printf 'MISS\t%s\n' "$rel" >&2; continue; }
			if [ "$action" = UPDATE ]; then
				# back up the loser FIRST, verified (rc + size). If the backup is not a faithful copy,
				# do NOT overwrite: an intact local save beats an unrecoverable one (guarantee #2).
				# Plain cp + set_mtime (touch-based, busybox-safe) carries the original mtime -- do not
				# rely on `cp -p`, which busybox may not support (would skip every UPDATE).
				omt=$(file_mtime "$dst/$rel")
				if ! mkdir -p "$bdir/$(dirname "$rel")" 2>/dev/null \
				   || ! cp "$dst/$rel" "$bdir/$rel" 2>/dev/null \
				   || [ "$(file_size "$dst/$rel")" != "$(file_size "$bdir/$rel")" ]; then
					rm -f "$bdir/$rel"; printf 'FAIL\t%s (backup)\n' "$rel" >&2; continue
				fi
				set_mtime "$bdir/$rel" "$omt"
			fi
			mkdir -p "$dst/$(dirname "$rel")"
			cp "$staging/$rel" "$dst/$rel.dsync.tmp" 2>/dev/null
			if [ "$(file_size "$staging/$rel")" = "$(file_size "$dst/$rel.dsync.tmp")" ]; then
				mv "$dst/$rel.dsync.tmp" "$dst/$rel"
				set_mtime "$dst/$rel" "$mtime"
				# ops.log carries the applied size so undo can tell an untouched ADD from a user-edited one
				printf '%s\t%s\t%s\n' "$action" "$(file_size "$dst/$rel")" "$rel" >> "$bdir/ops.log"
			else
				rm -f "$dst/$rel.dsync.tmp"; printf 'FAIL\t%s\n' "$rel" >&2
			fi ;;
		*) : ;;  # SKIP / KEEP-LOCAL / CONFLICT-ROM: no write, nothing lost
		esac
	done
}

# ---- public: dir-to-dir (src holds manifest + bytes) ----
plan()  { src="$1"; dst="$2"; t=$(tmpf); manifest "$src" > "$t"; _plan_rich "$t" "$dst" | cut -f1,3; rm -f "$t"; }
apply() { src="$1"; dst="$2"; bdir="$3"; t=$(tmpf); manifest "$src" > "$t"; _apply_rich "$t" "$src" "$dst" "$bdir"; rc=$?; rm -f "$t"; return $rc; }

# ---- public: networked (manifest fetched over the wire, bytes downloaded into staging) ----
delta()   { _plan_rich "$1" "$2" | grep -E '^(ADD|UPDATE)' | cut -f3; }   # receiver: files to download
plan_net(){ _plan_rich "$1" "$2" | cut -f1,3; }            # receiver: dry-run preview
apply_net(){ _apply_rich "$1" "$2" "$3" "$4"; }            # receiver: apply staged bytes

# ---- undo: restore the exact pre-sync state from a backup dir's ops.log ----
undo() {
	dst="$1"; bdir="$2"
	[ -f "$bdir/ops.log" ] || { echo "undo: no ops.log in $bdir" >&2; return 1; }
	while IFS="$TAB" read -r action size rel; do
		case "$action" in
			ADD)    # was new: remove it ONLY if unchanged since the sync, then clean now-empty dirs
				if [ "$(file_size "$dst/$rel")" = "$size" ]; then
					rm -f "$dst/$rel"
					d=$(dirname "$rel")
					while [ "$d" != "." ] && [ "$d" != "/" ]; do
						rmdir "$dst/$d" 2>/dev/null || break
						d=$(dirname "$d")
					done
				else
					printf 'UNDO-SKIP\t%s (changed since sync)\n' "$rel" >&2
				fi ;;
			UPDATE) # restore the original atomically (tmp+verify+rename), mtime restored; refuse if backup missing/short
				if [ -e "$bdir/$rel" ]; then
					mkdir -p "$dst/$(dirname "$rel")"
					cp "$bdir/$rel" "$dst/$rel.dsync.tmp" 2>/dev/null
					if [ "$(file_size "$bdir/$rel")" = "$(file_size "$dst/$rel.dsync.tmp")" ]; then
						mv "$dst/$rel.dsync.tmp" "$dst/$rel"
						set_mtime "$dst/$rel" "$(file_mtime "$bdir/$rel")"
					else
						rm -f "$dst/$rel.dsync.tmp"; printf 'UNDO-FAIL\t%s\n' "$rel" >&2
					fi
				else
					printf 'UNDO-MISS\t%s\n' "$rel" >&2
				fi ;;
		esac
	done < "$bdir/ops.log"
}

# ---- prune: keep the newest N backup snapshots (timestamp-named dirs) ----
prune() {
	root="$1"; keep="$2"
	n=$(ls -1 "$root" 2>/dev/null | wc -l | tr -d ' ')
	[ "$n" -gt "$keep" ] 2>/dev/null || return 0
	rmn=$((n - keep))
	ls -1 "$root" | sort | head -n "$rmn" | while IFS= read -r old; do rm -rf "$root/$old"; done
}

# ---- CLI dispatch ----
cmd="$1"; [ $# -gt 0 ] && shift
case "$cmd" in
	manifest)  manifest "$@" ;;
	plan)      plan "$@" ;;
	apply)     apply "$@" ;;
	delta)     delta "$@" ;;
	plan-net)  plan_net "$@" ;;
	apply-net) apply_net "$@" ;;
	undo)      undo "$@" ;;
	prune)     prune "$@" ;;
	classify)  classify "$@" ;;
	*) echo "usage: sync-engine.sh {manifest|plan|apply|delta|plan-net|apply-net|undo|prune|classify} ..." >&2; exit 2 ;;
esac
