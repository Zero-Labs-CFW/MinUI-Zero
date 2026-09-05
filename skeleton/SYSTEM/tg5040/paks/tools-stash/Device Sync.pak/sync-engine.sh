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
# Size via ls -ln (a stat), NEVER wc -c: busybox wc READS the whole file to count it, which on a card of
# PS1 disc images meant reading gigabytes just to size them (caught on the Brick 2026-09-05, wc found
# with a 600 MB .bin open). Field 5 of ls -ln is the byte size on busybox, GNU and BSD alike.
file_size()  { [ -e "$1" ] && ls -lnL "$1" 2>/dev/null | { read -r _p _l _u _g sz _rest; echo "${sz:-0}"; } || echo 0; }
# Pick the mtime tool ONCE. Every miss is a fork, and busybox (the device) has no stat at all, so the old
# try-each-in-turn shim cost three forks per file; date -r is what works there.
if   stat -c %Y . >/dev/null 2>&1; then MT=gnu
elif stat -f %m . >/dev/null 2>&1; then MT=bsd
else MT=date; fi
file_mtime() {
	case "$MT" in
		gnu) stat -c %Y "$1" 2>/dev/null ;;
		bsd) stat -f %m "$1" 2>/dev/null ;;
		*)   date -r "$1" +%s 2>/dev/null ;;
	esac || echo 0
}
file_hash()  {
	if   command -v md5sum >/dev/null 2>&1; then md5sum "$1" 2>/dev/null | cut -d' ' -f1
	elif command -v md5    >/dev/null 2>&1; then md5 -q "$1" 2>/dev/null
	else echo "nohash-$(file_size "$1")"; fi
}
fmt_ts()   { date -r "$1" +%Y%m%d%H%M.%S 2>/dev/null || date -d @"$1" +%Y%m%d%H%M.%S 2>/dev/null; }
set_mtime(){ [ "${2:-0}" -gt 0 ] 2>/dev/null || return 0; ts=$(fmt_ts "$2"); [ -n "$ts" ] && touch -t "$ts" "$1" 2>/dev/null; }  # 0 = unknown: leave the file's own time
tmpf()     { mktemp "${TMPDIR:-/tmp}/dsync.XXXXXX"; }

# ---- classification: relpath -> class, class -> merge rule ----
# _classify sets CLS with no fork (manifest() calls it once per file); classify is the echoing/CLI form.
_classify() {
	case "$1" in
		Roms/*)              CLS=rom ;;
		Saves/*)             CLS=save ;;
		*.st[0-9])           CLS=save ;;        # save states live in .userdata/shared/<tag>-<core>/<game>.st0..9 -- treat as a save (conflict-protected)
		Collections/*)       CLS=collection ;;
		*/recent.txt)        CLS=recent ;;      # the recently-played list (.userdata/shared/.minui/recent.txt)
		map.txt|*/map.txt)   CLS=map ;;
		*.cfg)               CLS=config ;;
		*)                   CLS=other ;;
	esac
}
classify() { _classify "$1"; echo "$CLS"; }
rule_for() { case "$1" in rom) echo additive ;; *) echo newer ;; esac; }  # rom never overwritten

# ---- manifest: rel \t size \t mtime \t class \t hash ----
# BATCHED, not per-file. The old loop forked wc + date + md5sum for every file; on a 765-game card that
# was thousands of busybox forks, minutes of wall clock, and a black screen (2026-09-05). Now: sizes for
# every file and md5 for every NON-ROM file come from a handful of `find -exec ... {} +` batches
# (verified on the Brick's busybox 1.27: no -printf, but {} + works). mtime is still one date -r per
# file but only for non-ROMs (saves/states/configs -- the few that matter); ROMs are additive, never
# overwritten, so their mtime is cosmetic and is emitted as 0 (set_mtime skips 0). Class comes from the
# shell _classify (single source of truth) with no fork. Filenames with spaces are preserved; the
# only unsupported names are ones containing a tab or newline.
manifest() {
	( cd "$1" 2>/dev/null || exit 0
	  t=$(tmpf)
	  # sizes: ls -lnL is a stat (field 5 = bytes; -L dereferences, or a symlinked FILE like recent.txt reports
	  # the link -- "name -> target", 46 bytes -- which broke that one download on 2026-09-05). wc -c would
	  # READ every file: gigabytes of PS1 images
	  find -L . -type f -exec ls -lnL {} + 2>/dev/null > "$t.sz"
	  find -L . -type f ! -path './Roms/*' -exec md5sum {} + 2>/dev/null > "$t.md5"
	  find -L . -type f ! -path './Roms/*' 2>/dev/null | while IFS= read -r f; do
		printf '%s\t%s\n' "$(file_mtime "$f")" "$f"; done > "$t.mt"
	  # the path is everything from the first " ./" (the fields before it are perms/counts/date)
	  awk '{ i=index($0," ./"); if (i) print substr($0,i+1) }' "$t.sz" | while IFS= read -r f; do
		_classify "${f#./}"; printf '%s\t%s\n' "$CLS" "$f"; done > "$t.cls"
	  awk -F'\t' -v OFS='\t' '
		FILENAME==ARGV[1] { i=index($0," ./"); if (i) { split($0,a," "); sz[substr($0,i+1)]=a[5] } next }
		FILENAME==ARGV[2] { h[substr($0,35)]=substr($0,1,32); next }
		FILENAME==ARGV[3] { mt[$2]=$1; next }
		FILENAME==ARGV[4] { f=$2; c=$1
		                    print substr(f,3), sz[f], (f in mt ? mt[f] : 0), c, (c=="rom" ? "-" : (f in h ? h[f] : "-")) }
	  ' "$t.sz" "$t.md5" "$t.mt" "$t.cls"
	  rm -f "$t" "$t.sz" "$t.md5" "$t.mt" "$t.cls" )
}

# ---- _plan_rich: compare a manifest against dst. Emits ACTION \t MTIME \t REL (internal form) ----
# Actions: ADD UPDATE SKIP KEEP-LOCAL CONFLICT-ROM. dst-only files never appear (never deleted).
# BATCHED like manifest(): the per-line shell version forked ~4 processes per manifest entry (size, class
# rule, hash) -- 33 s for 1,134 files on the Brick Pro, run three times per sync (plan, pull, apply). Now:
# ONE ls for every local file the manifest names, ONE md5sum for the non-ROM ones whose SIZE already
# matches (a size mismatch is a difference, no hash needed), and every decision in awk. Same actions,
# same order, same rules:
#   unsafe rel (absolute / ..)            -> UNSAFE to stderr, skipped (guards writes, backups, downloads)
#   not present locally                   -> ADD
#   rom (additive): size equal / not      -> SKIP / CONFLICT-ROM
#   size+hash equal                       -> SKIP (byte-identical, never re-copied)
#   differs, DS_MODE=ask: save / other    -> CONFLICT (user decides; the Mario Golf guard) / UPDATE
#   differs, DS_MODE=push                 -> UPDATE (sender wins, clock-independent)
#   differs, merge (unset): newer mtime   -> UPDATE / KEEP-LOCAL (host dir-to-dir only; needs local mtime)
_plan_rich() {
	mfile="$1"; dst="$2"
	t=$(tmpf)
	# rels to stat: everything the manifest names that is not a traversal attempt, as ./rel so the ls
	# line has a known " ./" anchor in front of a name that may contain spaces
	awk -F'\t' '$1 != "" && $1 !~ /^\// && $1 != ".." && $1 !~ /^\.\.\// && $1 !~ /\/\.\.$/ && $1 !~ /\/\.\.\// { print "./" $1 }' "$mfile" > "$t.rels"
	( cd "$dst" 2>/dev/null && tr '\n' '\0' < "$t.rels" | xargs -0 ls -lnL 2>/dev/null ) > "$t.sz"
	# hash candidates: non-ROM, present, size already equal
	awk -F'\t' -v OFS='\t' '
		FILENAME==ARGV[1] { i=index($0," ./"); if (i) { split($0,a," "); sz[substr($0,i+3)]=a[5] } next }
		$4 != "rom" && ($1 in sz) && sz[$1] == $2 { print "./" $1 }
	' "$t.sz" "$mfile" > "$t.cand"
	( cd "$dst" 2>/dev/null && tr '\n' '\0' < "$t.cand" | xargs -0 md5sum 2>/dev/null ) > "$t.md5"
	# merge mode (host tests) needs the local mtime of files that differ; on-device modes never do
	: > "$t.mt"
	if [ "$DS_MODE" != ask ] && [ "$DS_MODE" != push ]; then
		while IFS= read -r r; do r=${r#./}; [ -e "$dst/$r" ] && printf '%s\t%s\n' "$(file_mtime "$dst/$r")" "$r"; done < "$t.rels" > "$t.mt"
	fi
	awk -F'\t' -v OFS='\t' -v mode="${DS_MODE:-merge}" '
		FILENAME==ARGV[1] { i=index($0," ./"); if (i) { split($0,a," "); sz[substr($0,i+3)]=a[5] } next }
		FILENAME==ARGV[2] { h[substr($0,37)]=substr($0,1,32); next }
		FILENAME==ARGV[3] { mt[$2]=$1; next }
		{
			rel=$1; size=$2; mtime=$3; cls=$4; hash=$5
			if (rel == "") next
			if (rel ~ /^\// || rel == ".." || rel ~ /^\.\.\// || rel ~ /\/\.\.$/ || rel ~ /\/\.\.\//) { print "UNSAFE\t" rel > "/dev/stderr"; next }
			if (!(rel in sz)) { print "ADD", mtime, rel; next }
			if (cls == "rom") { print (sz[rel] == size ? "SKIP" : "CONFLICT-ROM"), mtime, rel; next }
			if (sz[rel] == size && hash != "-" && (rel in h) && h[rel] == hash) { print "SKIP", mtime, rel; next }
			if (mode == "ask")  { print (cls == "save" ? "CONFLICT" : "UPDATE"), mtime, rel; next }
			if (mode == "push") { print "UPDATE", mtime, rel; next }
			print ((mtime+0) > (mt[rel]+0) ? "UPDATE" : "KEEP-LOCAL"), mtime, rel
		}
	' "$t.sz" "$t.md5" "$t.mt" "$mfile"
	rm -f "$t" "$t.rels" "$t.sz" "$t.cand" "$t.md5" "$t.mt"
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
		if [ "$action" = CONFLICT ]; then
			# apply an approved conflict as an UPDATE (backup+atomic); otherwise keep local
			if [ -n "$DS_TAKE" ] && grep -qxF "$rel" "$DS_TAKE" 2>/dev/null; then action=UPDATE; else continue; fi
		fi
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
delta()   { _plan_rich "$1" "$2" | grep -E "^(ADD|UPDATE|CONFLICT)$TAB" | cut -f3; }   # receiver: files to download (conflicts staged too, applied only if approved)
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
