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
#   2. Always back up before replacing, and only ever behind a VERIFIED backup. The copy goes to
#      <bdir>/<rel>.dsync.part, is size-checked, and is mv'd into place, so a file in the backup dir is
#      always whole; apply-plan records that size in the journal and re-checks it before overwriting.
#      ops.log records every ADD/UPDATE so restore can put the EXACT pre-sync state back.
#   3. Never delete. A file only in dst is never touched; absence in the manifest is not a signal.
#   4. Backup-first BOTH ways (v2). restore snapshots the CURRENT state before putting originals back, so
#      a restore never discards what happened after the sync and is itself reversible. It replaces the old
#      undo, which guessed "did the user change this?" from the file size and lost fixed-size saves.
#   5. Crash-safe apply (v2). apply-plan journals every step, journal-status sees an interrupted apply and
#      resume-apply finishes it; resume-check says which staged files still need downloading.
#   6. Resume re-verifies the LIVE file (v2.1). The journal describes the card at the INTERRUPTION; the
#      user owns it in between (die mid-sync, play 20 hours, then resume). So resume-apply never trusts
#      the remembered state: before every write it re-checks what is on the card NOW and takes a fresh
#      verified backup if it is not already copied. An unreadable plan is an ERROR, never a COMPLETE.
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

# ---- system folders: identity by TAG --------------------------------------------------------------
# Games are identified by system TAG + file name, never by folder name: one card says "6) PlayStation (PS)",
# another "Sony PlayStation (PS)", and a path compare copied each folder to the other side (Dan, 2026-09-22).
# On the wire and in every plan/journal a game is Roms/<TAG>/<file>: build-export serves Roms/<TAG> as a
# symlink to the real folder, and apply/restore map Roms/<TAG>/ back to THIS card's folder through
# DSYNC_SYSMAP, a "TAG<tab>folder" file the launcher writes (local folders first, then the peer's names
# for tags this card lacks). No map, or an unknown tag: the path is used as it is (old backups too).
SYSMAP_STR=""
if [ -n "${DSYNC_SYSMAP:-}" ] && [ -f "$DSYNC_SYSMAP" ]; then
	SYSMAP_STR="$(awk -F"$TAB" '$1!="" && $2!="" { printf "|%s=%s", $1, $2 }' "$DSYNC_SYSMAP")|"
fi
local_rel() { # <rel> -> sets LREL (no subshell: this runs once per file)
	LREL=$1
	case "$1" in Roms/*/*)
		t=${1#Roms/}; t=${t%%/*}; r=${1#Roms/*/}
		case "$SYSMAP_STR" in *"|$t="*) f=${SYSMAP_STR#*"|$t="}; f=${f%%|*}; LREL="Roms/$f/$r" ;; esac ;;
	esac
}

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

# ---- verified backup + scratch hygiene (the never-lose-a-save primitives) ----
# _backup_one copies the LIVE file into the backup dir the same way applies write: .part, size check,
# atomic mv. That is what makes "a file exists in the backup dir" mean "a COMPLETE copy": before this,
# a cp cut by a power loss left a SHORT file at <bdir>/<rel>, and resume-apply trusted it as the
# pre-sync original and overwrote the real save behind it (the exact loss this engine exists to stop).
_backup_copy() { # <src file> <dest file> -> 0 = verified copy in place, 1 = could not (caller must NOT write)
	_bc_mt=$(file_mtime "$1")
	mkdir -p "$(dirname "$2")" 2>/dev/null || return 1
	rm -f "$2.dsync.part"
	cp "$1" "$2.dsync.part" 2>/dev/null || { rm -f "$2.dsync.part"; return 1; }
	[ "$(file_size "$1")" = "$(file_size "$2.dsync.part")" ] || { rm -f "$2.dsync.part"; return 1; }
	mv "$2.dsync.part" "$2" 2>/dev/null || { rm -f "$2.dsync.part"; return 1; }
	set_mtime "$2" "$_bc_mt"
	return 0
}
_backup_one() { # <dst> <bdir> <rel> [live rel] -> 0 = verified copy in place, 1 = could not (caller must NOT write)
	_backup_copy "$1/${4:-$3}" "$2/$3"
}
# byte-identical? size first (a stat), hash only when the sizes already agree. Used by resume to ask
# "is the backup I remember still a copy of the file that is on the card NOW?"
_same_bytes() { # <a> <b>
	[ -e "$1" ] && [ -e "$2" ] || return 1
	[ "$(file_size "$1")" = "$(file_size "$2")" ] || return 1
	[ "$(file_hash "$1")" = "$(file_hash "$2")" ]
}
# does this file ALREADY hold the bytes a plan line carries? size, plus the hash when the plan has one,
# else the MTIME. After a power cut that is how resume tells "the write landed" from "the write never
# started". A landed write carries the source mtime (apply stamps it); a write that never started, or a
# save the user changed AFTER the interruption, has a different mtime. Size alone is NOT enough now that
# saves are hashless: a fixed-size SRAM save edited after the cut is the same size but must be treated as
# changed, or resume overwrites the new progress uncopied (Codex, 2026-09-18).
_is_plan_copy() { # <file> <plan size> <plan hash> [plan mtime]
	[ -e "$1" ] || return 1
	[ "$(file_size "$1")" = "$2" ] || return 1
	if [ -n "$3" ] && [ "$3" != "-" ]; then [ "$(file_hash "$1")" = "$3" ]; return; fi
	[ -n "$4" ] && [ "$4" != 0 ] 2>/dev/null || return 0   # no hash AND no mtime (bare ROM): size is all there is
	m=$(file_mtime "$1"); case "$m" in ''|*[!0-9]*) return 1 ;; esac
	d=$((m - $4)); [ "$d" -eq 0 ] || [ "$d" -eq -1 ]   # FAT32 rounds an odd stamped second DOWN: 0 or -1 only
}
# sweep our own half-written scratch. A power cut between the tmp write and the atomic mv strands a
# <save>.dsync.tmp on the card forever; manifest() no longer sees them, this clears the dead bytes.
# Plan-scoped sweep: only the directories this plan writes can hold OUR scratch, and a full-card walk
# was O(library) on every apply (a 24 GB ROM set walked twice per sync, code review 2026-09-19).
sweep_tmp_plan() { # <plan-or-manifest> <dst> [relcol]   (rel column: 4 for a plan, 1 for a manifest)
	[ -d "$2" ] || return 0
	awk -F"$TAB" -v c="${3:-4}" '$c!="" { $4=$c } $4!="" { p=$4; sub(/\/[^\/]*$/,"",p); if (p==$4) p="."; print p }' "$1" | sort -u | while IFS= read -r d; do
		[ -d "$2/$d" ] && find "$2/$d" -maxdepth 1 -type f \( -name '*.dsync.tmp' -o -name '*.dsync.part' \) -exec rm -f {} + 2>/dev/null
	done; return 0
}
sweep_tmp() { # <dir>
	[ -d "$1" ] || return 0
	find "$1" -follow -type f \( -name '*.dsync.tmp' -o -name '*.dsync.part' \) -exec rm -f {} + 2>/dev/null
	return 0
}

# ---- classification: relpath -> class, class -> merge rule ----
# _classify sets CLS with no fork (manifest() calls it once per file); classify is the echoing/CLI form.
_classify() {
	case "$1" in
		*.sync-conflict-*)   CLS=other ;;      # Syncthing conflict copies on a card: never ours to sync (Dan, 2026-09-21)
		Roms/*)              CLS=rom ;;
		Bios/*)              CLS=rom ;;       # a BIOS travels with Games: existence by name, never overwritten (Dan, 2026-09-22)
		Saves/*)             CLS=save ;;
		.userdata/shared/.minui/*/*) CLS=save ;;     # state PREVIEWS <game>.<slot>.bmp, last-slot <game>.txt, disc pointer <game>.<slot>.txt: .minui/<TAG>/, named by tag alone (Dan, 2026-09-22)
		*.st[0-9]|*.st[0-9].*) CLS=save ;;      # save states + their sidecars (.st0, .st0.png thumbnail, ...) in .userdata/shared/<tag>-<core>/ -- all save data
		Collections/*)       CLS=collection ;;
		*/recent.txt)        CLS=other ;;       # Recently Played is per-device activity: never synced (Dan, 2026-09-21)
		*/favorites.txt)     CLS=favorite ;;    # the favorites list, beside recent.txt -- syncs with the save bundle
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
	  # Identity is SIZE + MTIME, never a content hash. Hashing read every save/state off the card and was
	  # the slow part; size+mtime is a pure stat. An emulator bumps mtime on every write, and apply stamps
	  # the source mtime onto the copy, so a file already in sync reads identical next time and is skipped.
	  # The hash column is kept as "-" for format compatibility (build_plan and resume-check tolerate it).
	  # ls -lnL is a stat (field 5 = bytes; -L dereferences a symlinked file to its target). find -follow,
	  # Hidden files (basename starting with a dot) never sync: macOS drops ._name and .DS_Store beside every
	  # file it copies to a card, and MinUI hides them too (Dan, 2026-09-22: "lots of garbage files").
	  # Windows leaves Thumbs.db / ehthumbs.db / desktop.ini inside game folders: same treatment.
	  # Nor anything INSIDE a hidden folder: Syncthing keeps its marker at Saves/.stfolder/syncthing-folder-*.txt
	  # and it showed up as a save called syncthing-folder-9525ed (Smart Pro, 2026-09-22). The walk starts at the
	  # export root, so ./*/.*/* spares the .userdata scope root itself and drops hidden folders below any root,
	  # except MinUI's own .minui (favorites.txt, recent.txt, collections live there).
	  # NOT find -L: the Miyoo's busybox 1.20.2 has no -L and errors out. *.dsync.tmp/.part are our own
	  # half-written scratch, never user files.
	  # ONE pass for size AND mtime when stat -c exists (every device we ship: Brick, Miyoo, Plus): the
	  # separate ls -lnL size pass alone cost 6 s of the Miyoo's 16 s manifest (profiled 2026-09-20).
	  if [ "$MT" = gnu ]; then
		# stat -L: build-export serves recent.txt/favorites.txt as FILE symlinks, and busybox 1.27 stat without
		# -L reported the link itself (42 bytes, export time), so the plan carried a size no download could
		# ever match (QA 2026-09-20). NF==3 drops a name containing a tab, which would otherwise become a
		# phantom path that fails the whole bundle.
		find . -follow -type f ! -name '.*' \( -path '*/.minui/*' -o ! -path './*/.*/*' \) ! -name 'Thumbs.db' ! -name 'ehthumbs.db' ! -name 'desktop.ini' ! -name '*.dsync.tmp' ! -name '*.dsync.part' ! -name '*.gov' ! -name '*.thread' -exec stat -L -c "%s$TAB%Y$TAB%n" {} + 2>/dev/null > "$t.st"
		# same shape the old passes produced, so the join below is unchanged: sizes as a fake ls line, mtimes only for non-ROMs
		awk -F"$TAB" 'NF==3 { print "- - - - " $1 " x x x " $3 }' "$t.st" > "$t.sz"
		awk -F"$TAB" -v OFS="$TAB" 'NF==3 && $3 !~ /^\.\/Roms\// { print $2, $3 }' "$t.st" > "$t.mt"
	  else
	  find . -follow -type f ! -name '.*' \( -path '*/.minui/*' -o ! -path './*/.*/*' \) ! -name 'Thumbs.db' ! -name 'ehthumbs.db' ! -name 'desktop.ini' ! -name '*.dsync.tmp' ! -name '*.dsync.part' ! -name '*.gov' ! -name '*.thread' -exec ls -lnL {} + 2>/dev/null > "$t.sz"
	  # ROMs are existence-by-name (mtime never used, emitted as 0), so skip the per-file mtime fork for
	  # them -- with Games on that is one date/stat fork PER GAME, the fork-storm class this file fixes.
	  # ONE stat for every non-ROM file (`-exec {} +` batches), not one fork per file: 920 saves/states on
	  # the Miyoo took 16 s of forks (measured 2026-09-20). The per-file loop stays as the fallback for a
	  # busybox without stat -c.
	  find . -follow -type f ! -path './Roms/*' ! -name '.*' \( -path '*/.minui/*' -o ! -path './*/.*/*' \) ! -name 'Thumbs.db' ! -name 'ehthumbs.db' ! -name 'desktop.ini' ! -name '*.dsync.tmp' ! -name '*.dsync.part' ! -name '*.gov' ! -name '*.thread' 2>/dev/null | while IFS= read -r f; do
		printf '%s\t%s\n' "$(file_mtime "$f")" "$f"; done > "$t.mt"
	  fi
	  # the path is everything from the first " ./" (the fields before it are perms/counts/date)
	  awk '{ i=index($0," ./"); if (i) print substr($0,i+1) }' "$t.sz" | while IFS= read -r f; do
		_classify "${f#./}"; printf '%s\t%s\n' "$CLS" "$f"; done > "$t.cls"
	  awk -F"$TAB" -v OFS='\t' '
		FILENAME==ARGV[1] { i=index($0," ./"); if (i) { split($0,a," "); sz[substr($0,i+1)]=a[5] } next }
		FILENAME==ARGV[2] { mt[$2]=$1; next }
		FILENAME==ARGV[3] { f=$2; c=$1
		                    if (c == "other") next   # unclassified files never sync (avoids a category the both-on rule cannot place)
		                    print substr(f,3), sz[f], (f in mt ? mt[f] : 0), c, "-" }
	  ' "$t.sz" "$t.mt" "$t.cls"
	  rm -f "$t" "$t.st" "$t.sz" "$t.mt" "$t.cls" )
}

# ---- _plan_rich: compare a manifest against dst. Emits ACTION \t MTIME \t REL (internal form) ----
# Actions: ADD UPDATE SKIP KEEP-LOCAL CONFLICT. dst-only files never appear (never deleted).
# BATCHED like manifest(): the per-line shell version forked ~4 processes per manifest entry (size, class
# rule, hash) -- 33 s for 1,134 files on the Brick Pro, run three times per sync (plan, pull, apply). Now:
# ONE ls for every local file the manifest names, ONE md5sum for the non-ROM ones whose SIZE already
# matches (a size mismatch is a difference, no hash needed), and every decision in awk. Same actions,
# same order, same rules:
#   unsafe rel (absolute / ..)            -> UNSAFE to stderr, skipped (guards writes, backups, downloads)
#   not present locally                   -> ADD
#   rom (additive): present by name        -> SKIP (existence only; content/date ignored)
#   size+hash equal                       -> SKIP (byte-identical, never re-copied)
#   differs, DS_MODE=ask: save / other    -> CONFLICT (user decides; the Mario Golf guard) / UPDATE
#   differs, DS_MODE=push                 -> UPDATE (sender wins, clock-independent)
#   differs, merge (unset): newer mtime   -> UPDATE / KEEP-LOCAL (host dir-to-dir only; needs local mtime)
_plan_rich() {
	mfile="$1"; dst="$2"
	t=$(tmpf)
	# rels to stat: everything the manifest names that is not a traversal attempt, as ./rel so the ls
	# line has a known " ./" anchor in front of a name that may contain spaces
	awk -F"$TAB" '$1 != "" && $1 !~ /^\// && $1 != ".." && $1 !~ /^\.\.\// && $1 !~ /\/\.\.$/ && $1 !~ /\/\.\.\// { print "./" $1 }' "$mfile" > "$t.rels"
	( cd "$dst" 2>/dev/null && tr '\n' '\0' < "$t.rels" | xargs -0 ls -lnL 2>/dev/null ) > "$t.sz"
	# hash candidates: non-ROM, present, size already equal
	awk -F"$TAB" -v OFS='\t' '
		FILENAME==ARGV[1] { i=index($0," ./"); if (i) { split($0,a," "); sz[substr($0,i+3)]=a[5] } next }
		$4 != "rom" && $5 != "-" && ($1 in sz) && sz[$1] == $2 { print "./" $1 }
	' "$t.sz" "$mfile" > "$t.cand"
	( cd "$dst" 2>/dev/null && tr '\n' '\0' < "$t.cand" | xargs -0 md5sum 2>/dev/null ) > "$t.md5"
	# local mtime of every present file. Identity is size + mtime now (no hash), so EVERY mode needs it
	# to tell "already have this exact file" from "same size, different version".
	: > "$t.mt"
	while IFS= read -r r; do r=${r#./}; [ -e "$dst/$r" ] && printf '%s\t%s\n' "$(file_mtime "$dst/$r")" "$r"; done < "$t.rels" > "$t.mt"
	awk -F"$TAB" -v OFS='\t' -v mode="${DS_MODE:-merge}" '
		FILENAME==ARGV[1] { i=index($0," ./"); if (i) { split($0,a," "); sz[substr($0,i+3)]=a[5] } next }
		FILENAME==ARGV[2] { h[substr($0,37)]=substr($0,1,32); next }
		FILENAME==ARGV[3] { mt[$2]=$1; next }
		{
			rel=$1; size=$2; mtime=$3; cls=$4; hash=$5
			if (rel == "") next
			if (rel ~ /^\// || rel == ".." || rel ~ /^\.\.\// || rel ~ /\/\.\.$/ || rel ~ /\/\.\.\//) { print "UNSAFE\t" rel > "/dev/stderr"; next }
			if (!(rel in sz)) { print "ADD", mtime, rel; next }
			if (cls == "rom") { print "SKIP", mtime, rel; next }   # ROMs: existence by name only. Same relpath = you have that game; content/date never matter (Dan 2026-09-18). Absent ROMs were already ADD above.
			# already have this EXACT file: same size AND same mtime (a synced copy shares the stamped
			# source mtime), plus a matching hash when the manifest still carries one (test fixtures).
			if (sz[rel] == size && (rel in mt) && mtime == mt[rel] && (hash == "-" || ((rel in h) && h[rel] == hash))) { print "SKIP", mtime, rel; next }
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
	sweep_tmp_plan "$mfile" "$dst" 1        # clear scratch a previous run's power cut stranded here
	ar=$(tmpf)          # its own name: _plan_rich below reuses the shared $t
	# fed by a FILE, not a pipe: a pipe runs the loop in a subshell, and the caller would get the
	# pipeline's status instead of ours -- a partial apply then looks like a clean one
	_plan_rich "$mfile" "$dst" > "$ar.plan"
	rc=0
	while IFS="$TAB" read -r action mtime rel; do
		if [ "$action" = CONFLICT ]; then
			# apply an approved conflict as an UPDATE (backup+atomic); otherwise keep local
			if [ -n "$DS_TAKE" ] && grep -qxF "$rel" "$DS_TAKE" 2>/dev/null; then action=UPDATE; else continue; fi
		fi
		case "$action" in
		ADD|UPDATE)
			[ -e "$staging/$rel" ] || { printf 'MISS\t%s\n' "$rel" >&2; rc=1; continue; }
			if [ "$action" = UPDATE ]; then
				# back up the loser FIRST, verified (rc + size). If the backup is not a faithful copy,
				# do NOT overwrite: an intact local save beats an unrecoverable one (guarantee #2).
				# Plain cp + set_mtime (touch-based, busybox-safe) carries the original mtime -- do not
				# rely on `cp -p`, which busybox may not support (would skip every UPDATE).
				# _backup_one writes .part + size check + atomic mv, so a power cut can never leave a
				# SHORT file at <bdir>/<rel> for a later run to mistake for the pre-sync original
				_backup_one "$dst" "$bdir" "$rel" || { printf 'FAIL\t%s (backup)\n' "$rel" >&2; rc=1; continue; }
			fi
			mkdir -p "$dst/$(dirname "$rel")"
			cp "$staging/$rel" "$dst/$rel.dsync.tmp" 2>/dev/null
			if [ "$(file_size "$staging/$rel")" = "$(file_size "$dst/$rel.dsync.tmp")" ]; then
				mv "$dst/$rel.dsync.tmp" "$dst/$rel"
				set_mtime "$dst/$rel" "$mtime"
				# ops.log carries the applied size so undo can tell an untouched ADD from a user-edited one
				printf '%s\t%s\t%s\n' "$action" "$(file_size "$dst/$rel")" "$rel" >> "$bdir/ops.log"
			else
				rm -f "$dst/$rel.dsync.tmp"; printf 'FAIL\t%s\n' "$rel" >&2; rc=1
			fi ;;
		*) : ;;  # SKIP / KEEP-LOCAL / CONFLICT-ROM: no write, nothing lost
		esac
	done < "$ar.plan"
	rm -f "$ar" "$ar.plan"
	return $rc
}

# ---- public: dir-to-dir (src holds manifest + bytes) ----
plan()  { src="$1"; dst="$2"; t=$(tmpf); manifest "$src" > "$t"; _plan_rich "$t" "$dst" | cut -f1,3; rm -f "$t"; }
apply() { src="$1"; dst="$2"; bdir="$3"; t=$(tmpf); manifest "$src" > "$t"; _apply_rich "$t" "$src" "$dst" "$bdir"; rc=$?; rm -f "$t"; return $rc; }

# ---- public: networked (manifest fetched over the wire, bytes downloaded into staging) ----
delta()   { _plan_rich "$1" "$2" | grep -E "^(ADD|UPDATE|CONFLICT)$TAB" | cut -f3; }   # receiver: files to download (conflicts staged too, applied only if approved)
plan_net(){ _plan_rich "$1" "$2" | cut -f1,3; }            # receiver: dry-run preview (ACTION \t REL)
# ---- the at-a-glance delta: what actually needs to sync, per category (Dan 2026-09-18) ----
# plan_rich joins the plan with the manifest so every planned file carries its class + size; the
# at-a-glance screen and the per-category drill-in are both built from it.
plan_rich(){ # <manifest> <dst> : ACTION \t CLASS \t SIZE \t REL  (one line per planned file)
	_plan_rich "$1" "$2" | awk -F"$TAB" -v OFS="$TAB" '
		FNR==NR { cls[$1]=$4; sz[$1]=$2; next }                     # manifest: rel size mtime class hash
		{ rel=$3; print $1, (rel in cls ? cls[rel] : "other"), (rel in sz ? sz[rel] : 0), rel }
	' "$1" -
}
# plan_summary rolls plan_rich up to the counts the receiver shows at a glance. One line per class that
# has anything to copy, then a TOTAL: CLASS \t items \t bytes \t new \t changed \t conflicts. Only the
# copy actions (ADD/UPDATE/CONFLICT) count; SKIP/KEEP-LOCAL are already-in-sync and never shown.
plan_summary(){ # <manifest> <dst>
	plan_rich "$1" "$2" | awk -F"$TAB" -v OFS="$TAB" '
		$1=="ADD" || $1=="UPDATE" || $1=="CONFLICT" {
			c=$2; n[c]++; b[c]+=$3; tn++; tb+=$3
			if ($1=="ADD") nw[c]++; else if ($1=="CONFLICT") cf[c]++; else ch[c]++
		}
		END { for (c in n) print c, n[c], b[c]+0, nw[c]+0, ch[c]+0, cf[c]+0; print "TOTAL", tn+0, tb+0, 0, 0, 0 }
	'
}
# ---- bidirectional merge: given BOTH devices' manifests, decide which way each file should travel so
# one run leaves both in sync (Dan 2026-09-18: "bidirectional for launch"). A and B are the two devices.
#   DIR \t CLASS \t SIZE \t REL, DIR in: to-b (A's copy -> B), to-a (B's copy -> A), conflict (ask), skip.
#   rom: existence only (present on both = skip; present on one = goes to the other; never a conflict).
#   save: differs on both = conflict (never auto-picked; the two-version picker resolves it).
#   config/recent/collection/other: newer mtime wins (tie -> to-b); identical hash = skip.
# The clock is advisory, so a save is never auto-resolved by mtime -- only non-precious files are.
merge_manifests(){ # <A-manifest> <B-manifest> [A-clock minus B-clock] [B boot, B clock] [A boot, A clock]
	# pboot: a device with no RTC restores its clock at boot, so its lag is only known for files written
	# THIS session; an older file carries a smaller lag and would be pushed into the future by the full
	# offset (a week-old Miyoo save beating three-day-old Brick progress, QA 2026-09-20). Older: raw.
	# off corrects B's mtimes into A's clock for the NEWEST-WINS direction only. Identity (size+mtime)
	# stays raw on purpose: apply stamps the source mtime, so a synced pair matches without any offset.
	awk -F"$TAB" -v OFS="$TAB" -v off="${3:-0}" -v pboot="${4:-0}" -v aboot="${5:-0}" '
		FILENAME==ARGV[1] { a[$1]=1; ac[$1]=$4; asz[$1]=$2; amt[$1]=$3; ah[$1]=$5; next }
		{ rel=$1; bsz=$2; bmt=$3; bc=$4; bh=$5; b[rel]=1
		  if (!(rel in a)) { print "to-a", bc, bsz, rel; next }             # only on B -> send to A
		  if (bc=="rom") { print "skip", bc, bsz, rel; next }               # both have the game (by name)
		  # identical? use the hashes if BOTH manifests carry them (test fixtures), otherwise size+mtime
		  # (the real, hashless snapshots -- a synced file shares the stamped source mtime, so it matches)
		  if (ah[rel]!="-" && bh!="-") { if (ah[rel]==bh) { print "skip", bc, bsz, rel; next } }
		  # 1 s window, not equality: FAT32 stores mtime to 2 s, so a stamped odd second reads back one lower
		  # and an exFAT/FAT32 pair re-copied every odd save on every sync (QA 2026-09-20)
		  else if (asz[rel]==bsz && amt[rel]-bmt <= 1 && bmt-amt[rel] <= 1) { print "skip", bc, bsz, rel; next }
		  # list files (Favorites, a Collection) are MERGED, not replaced: both sides take the other copy and
		  # apply unions the lines, so an entry added on either device ends up on both (Dan, 2026-09-21)
		  if (bc=="favorite" || bc=="collection") { print "to-a", bc, bsz, rel; print "to-b", bc, asz[rel], rel; next }
		  if (bc=="save") { print "conflict", bc, bsz, rel; next }          # differing save: ask
		  # the offset is only known for THIS session on each side: a file older than the boot of its own device -> raw
		  bm = ((pboot > 0 && (bmt+0) < pboot) || (aboot > 0 && (amt[rel]+0) < aboot)) ? bmt+0 : bmt+0+off
		  if ((amt[rel]+0) >= bm) { print "to-b", bc, asz[rel], rel }         # newer wins (tie -> A)
		  else { print "to-a", bc, bsz, rel }
		}
		END { for (rel in a) if (!(rel in b)) print "to-b", ac[rel], asz[rel], rel }  # only on A -> send to B
	' "$1" "$2"
}
# roll the bidirectional merge up to the at-a-glance counts, per direction and category.
merge_summary(){ # <A-manifest> <B-manifest> : DIR \t CLASS \t items \t bytes  (+ TOTAL per direction)
	merge_manifests "$1" "$2" | awk -F"$TAB" -v OFS="$TAB" '
		$1!="skip" { d=$1; c=$2; n[d,c]++; by[d,c]+=$3; tn[d]++; tby[d]+=$3; dseen[d]=1; cseen[c]=1 }
		END { for (d in dseen) { for (c in cseen) if ((d,c) in n) print d, c, n[d,c], by[d,c]; print d, "TOTAL", tn[d], tby[d] } }
	'
}
apply_net(){ _apply_rich "$1" "$2" "$3" "$4"; }            # receiver: apply staged bytes

# ---- apply-plan: apply ONE authoritative plan, crash-safely (Device Sync v2) ----
# v2 computes the merge ONCE (on the host) and hands both devices the same plan, so this applies a plan
# instead of re-deciding: ACTION \t CLASS \t SIZE \t REL [\t HASH \t MTIME]. ACTION "take" = copy
# <staging>/<rel> over <dst>/<rel>; anything else is ignored. HASH and MTIME are OPTIONAL trailing
# columns -- HASH lets resume-check verify a staged file byte-for-byte, MTIME stamps the sender's time on
# the applied file (wget does not preserve mtime, so without it every fresh download looks "newer" than
# local on the NEXT sync). A 4-column plan still works; it just falls back to size-only resume checks.
#
# Order per file, and why every step is journalled: BEGIN -> back up whatever is in dst NOW -> record the
# backup kind -> tmp write + size verify + atomic mv -> ops.log -> DONE. A power cut can land anywhere in
# that sequence, so the journal has to say where it landed: resume-apply must NOT re-run the backup step
# for a file whose write already landed, because that would copy the SYNCED bytes over the pre-sync
# original in the backup dir -- exactly the data loss this file exists to prevent. COMPLETE is appended
# only when every planned file is applied, so journal-status can tell "finished" from "interrupted".
#
# ops.log stays in the old ADD/UPDATE format: it is the restore record (ADD = nothing was here before,
# UPDATE = the pre-sync file is at <backupdir>/<rel>), so old backup dirs restore with the same code.
_apply_plan() { # <new|resume> <planfile> <staging> <dst> <backupdir>
	mode="$1"; plan="$2"; staging="$3"; dst="$4"; bdir="$5"
	# FAIL CLOSED on a plan we cannot read, BEFORE anything else. An unreadable/missing/empty plan used to
	# produce an empty work list, return 0 and stamp COMPLETE -- permanently turning an interrupted
	# transaction into a "finished" one, after which the caller drops the resume pointer and the staging
	# dir and the half-applied sync can never be finished. No plan = no work list = error, never COMPLETE.
	[ -f "$plan" ] && [ -r "$plan" ] && [ -s "$plan" ] || {
		echo "apply-plan: cannot read plan ($plan)" >&2; return 1; }
	if [ "$mode" = new ]; then
		# fail closed on a reused backup dir: clobbering a prior snapshot's ops.log would strand its restore
		if [ -e "$bdir/ops.log" ] || [ -e "$bdir/journal.log" ]; then
			echo "apply-plan: backup dir already used ($bdir); refusing to clobber a prior snapshot" >&2; return 1
		fi
		mkdir -p "$bdir" || { echo "apply-plan: cannot create $bdir" >&2; return 1; }
		: > "$bdir/journal.log"; : > "$bdir/ops.log"
	else
		[ -f "$bdir/journal.log" ] || { echo "resume-apply: no journal in $bdir" >&2; return 1; }
		[ "$(journal_status "$bdir")" = COMPLETE ] && return 0   # already finished: nothing to redo
		[ -f "$bdir/ops.log" ] || : > "$bdir/ops.log"
	fi
	jl="$bdir/journal.log"
	# clear any <file>.dsync.tmp a previous run's power cut stranded on the card, so the card never
	# accumulates half-written scratch that a later sync would otherwise carry around
	sweep_tmp_plan "$plan" "$dst"
	t=$(tmpf)
	# ONE pass over the journal + plan builds the work list: drop what is already DONE, carry the recorded
	# backup kind for a file that was interrupted after its backup. rel goes LAST so `read` soaks up the
	# rest of the line (the only unsupported filenames are ones containing a tab or newline).
	# A BACKUP line carries the SIZE the copy was verified at (BACKUP \t state \t size \t rel), so a
	# backup that later vanishes or shrinks is caught before anything is overwritten behind it. Old
	# 3-field BACKUP lines are ignored on purpose: no recorded size = no proof, so that file re-derives
	# its backup state below instead of being trusted. No field may be empty -- tab is IFS whitespace,
	# so `read` would collapse an empty one and shift every later field.
	# rec counts the lines that ARE plan lines; zero of them means this file is not a plan at all, so
	# awk exits 3 and we fail closed rather than "finish" a transaction we never read any work for.
	if ! awk -F"$TAB" -v OFS="$TAB" '
		FILENAME==ARGV[1] { if ($1=="DONE") done[$3]=1; else if ($1=="BACKUP" && $4 != "") { bk[$4]=$2; bs[$4]=$3 } next }
		{
			act=$1; rel=$4
			if (act == "take" || act == "skip") rec++
			if (rel == "") next
			if (act != "take") { if (act != "skip" && act != "") print "IGNORED\t" act "\t" rel > "/dev/stderr"; next }
			if (rel ~ /^\// || rel == ".." || rel ~ /^\.\.\// || rel ~ /\/\.\.$/ || rel ~ /\/\.\.\//) { print "UNSAFE\t" rel > "/dev/stderr"; next }
			if (rel in done) next
			if (seen[rel]++) next          # a rel listed twice would "back up" its own freshly-applied bytes
			print act, (rel in bk ? bk[rel] : "-"), (rel in bs && bs[rel] != "" ? bs[rel] : "-"), \
			      ($6 == "" ? 0 : $6), ($3 == "" ? 0 : $3), ($5 == "" ? "-" : $5), ($2 == "" ? "-" : $2), rel
		}
		END { if (rec+0 == 0) exit 3 }
	' "$jl" "$plan" > "$t.work"; then
		echo "apply-plan: unusable plan ($plan)" >&2; rm -f "$t" "$t.work"; return 1
	fi
	rc=0
	# fed by a FILE, not a pipe: a pipe would run the loop in a subshell and lose rc
	while IFS="$TAB" read -r action bkstate bksz mtime psize phash pcls rel; do
		[ -n "$rel" ] || continue
		local_rel "$rel"   # live path on THIS card (LREL); journal, ops.log, staging and backups keep the wire rel
		printf 'BEGIN\t%s\n' "$rel" >> "$jl"
		if [ "$bkstate" = "-" ]; then
			# No journalled backup. Back up the loser FIRST, verified: if the backup is not a faithful
			# copy, do NOT overwrite -- an intact local save beats an unrecoverable one.
			rm -f "$bdir/$rel.dsync.part"          # a torn copy from a power cut, never trusted
			if [ -e "$bdir/$rel" ]; then
				# A file in the backup dir is always WHOLE (_backup_one mv's it into place), but with no
				# journal line we still have to prove WHAT it copied before overwriting anything.
				# bytes, not just size: a save the user edited AFTER the cut can be the same size as the copy
				# taken before it -- overwriting that behind a stale backup is exactly the loss this guards
				if [ -e "$dst/$LREL" ] && ! cmp -s "$bdir/$rel" "$dst/$LREL" 2>/dev/null \
				   && ! _is_plan_copy "$dst/$LREL" "$psize" "$phash" "$mtime"; then
					# The live file does not match the plan, so this file's write never landed and the live
					# file IS the pre-sync original -- which this mismatched leftover therefore is not a
					# copy of. Two cases. A TORN stub from a pre-fix build (an interrupted cp) is a shorter PREFIX of
					# the live original: redo the backup, verified, and apply. Anything else means the user played
					# on after the cut (this build mv's whole copies only): the live file is the newest state, so
					# KEEP it, skip this write, and leave the leftover as the pre-sync copy (Codex 2026-09-21).
					lsz=$(file_size "$bdir/$rel"); dsz=$(file_size "$dst/$LREL")
					if [ "$lsz" -lt "$dsz" ] 2>/dev/null && head -c "$lsz" "$dst/$LREL" 2>/dev/null | cmp -s - "$bdir/$rel" 2>/dev/null; then
						rm -f "$bdir/$rel"
						if _backup_one "$dst" "$bdir" "$rel" "$LREL"; then bkstate=have; else bkstate=fail; fi
					else
						printf 'DONE\tkeep\t%s\n' "$rel" >> "$jl"; printf 'KEEP\t%s (edited after the interruption)\n' "$rel" >&2; continue
					fi
				else
					bkstate=have                   # a faithful copy of the live file, or the write already landed
				fi
			elif [ -e "$dst/$LREL" ]; then
				if _backup_one "$dst" "$bdir" "$rel" "$LREL"; then bkstate=have; else bkstate=fail; fi
			else
				bkstate=none                       # nothing here before: restoring this file means removing it
			fi
			bksz=0; [ "$bkstate" = have ] && bksz=$(file_size "$bdir/$rel")
			# a FAILED backup is deliberately not journalled: leaving it unrecorded makes the next
			# resume-apply try the backup again (a full card that gets cleared should recover)
			[ "$bkstate" = fail ] || printf 'BACKUP\t%s\t%s\t%s\n' "$bkstate" "$bksz" "$rel" >> "$jl"
		elif [ "$bkstate" = have ] && [ "$bksz" != "-" ] && [ "$(file_size "$bdir/$rel")" != "$bksz" ]; then
			# the journal says the pre-sync copy is in the backup dir, but it is gone or no longer the size
			# it was verified at: refuse rather than overwrite behind a backup that cannot be trusted
			printf 'FAIL\t%s (backup damaged)\n' "$rel" >&2; rc=1; continue
		elif [ -e "$dst/$LREL" ] && ! _is_plan_copy "$dst/$LREL" "$psize" "$phash" "$mtime"; then
			# RESUME, and this file's write never landed. The journal describes the card AS IT WAS AT THE
			# INTERRUPTION, but the user has had the device since: a battery death, then 20 hours of play
			# before they pick "Resume interrupted sync". So re-verify against the file that is on the card
			# NOW, never the remembered one -- trusting the memory wrote staged bytes over live user data
			# with only a stale (or no) copy behind it. Live bytes are never overwritten uncopied.
			if [ "$bkstate" = none ]; then
				# journalled "nothing was here" -- there is now, so the user CREATED it after the interruption.
				# That is the newest state: KEEP it and skip the stale staged write (it used to be backed up and
				# then replaced, Codex review 2026-09-21). No ops.log line, so restore leaves it alone.
				printf 'DONE\tkeep\t%s\n' "$rel" >> "$jl"; printf 'KEEP\t%s (created after the interruption)\n' "$rel" >&2; continue
			elif ! _same_bytes "$dst/$LREL" "$bdir/$rel"; then
				# the live file changed AFTER the backup was taken: the user played on. The plan was newest-wins
				# when it was computed, and the live bytes are the newest now, so KEEP them and skip this write.
				# It used to park the edit as <rel>.dsync.kept (unreachable from any screen, pruned after five
				# syncs) and write the stale staged bytes over it (QA 2026-09-20). No ops.log line, so restore
				# leaves it alone; DONE keep so the transaction can complete.
				printf 'DONE\tkeep\t%s\n' "$rel" >> "$jl"; printf 'KEEP\t%s (edited after the interruption)\n' "$rel" >&2; continue
			fi
		fi
		if [ "$bkstate" = fail ]; then
			printf 'FAIL\t%s (backup)\n' "$rel" >&2; rc=1; continue          # left unfinished on purpose
		fi
		# a cut between the final rename and its journal line: the write LANDED (the live file is the plan
		# copy) and the staged file was moved away, so there is nothing to redo. Record it now, ops.log
		# included, or a resume would report MISS forever and Restore would not know the file (Codex 2026-09-21)
		# (never on size alone: a ROM is identity-by-name, anything else needs the hash or the mtime)
		if [ ! -e "$staging/$rel" ] && { [ "$pcls" = rom ] || [ "${mtime:-0}" != 0 ] || [ "${phash:--}" != - ]; } \
		   && _is_plan_copy "$dst/$LREL" "$psize" "$phash" "$mtime"; then
			if ! awk -F"$TAB" -v r="$rel" '$3==r {f=1} END {exit !f}' "$bdir/ops.log" 2>/dev/null; then op=UPDATE; [ "$bkstate" = none ] && op=ADD; printf '%s\t%s\t%s\n' "$op" "$(file_size "$dst/$LREL")" "$rel" >> "$bdir/ops.log"; fi
			printf 'DONE\t%s\t%s\n' "$action" "$rel" >> "$jl"; continue
		fi
		if [ ! -e "$staging/$rel" ]; then
			printf 'MISS\t%s\n' "$rel" >&2; rc=1; continue                   # not downloaded: resume-apply retries it
		fi
		# the staged copy must BE the planned bytes: a power cut in the page-cache window leaves a zero-length
		# staged file on FAT, and verifying the tmp against that file applied 0 bytes over a save (QA 2026-09-20)
		# ONE size read per file: this loop is fork-bound on the device (871 games sat "saving" for minutes,
		# 2026-09-22), so the staged size is read once and reused for the check, the rename and the ops line
		ssz=$(file_size "$staging/$rel")
		if [ "${psize:-0}" != 0 ]; then
			if [ "$ssz" != "$psize" ] || { [ -n "$phash" ] && [ "$phash" != "-" ] && [ "$(file_hash "$staging/$rel")" != "$phash" ]; }; then
				printf 'MISS\t%s (staged copy is not the planned %s bytes)\n' "$rel" "$psize" >&2; rc=1; continue
			fi
		fi
		ld=${LREL%/*}; [ "$ld" = "$LREL" ] || [ -d "$dst/$ld" ] || mkdir -p "$dst/$ld"
		if { [ "$pcls" = favorite ] || [ "$pcls" = collection ]; } && [ -f "$dst/$LREL" ]; then
			# a LIST file: write the union of both sides, one entry per line, sorted (the launcher sorts these
			# lists itself, so file order carries nothing). Both devices compute the same bytes and stamp the
			# later of the two mtimes, so the pair reads identical on the next sync. The pre-union file is
			# already backed up above, so Restore still puts it back (Dan, 2026-09-21).
			lm=$(file_mtime "$dst/$LREL"); case "$lm" in ''|*[!0-9]*) lm=0 ;; esac
			{ cat "$dst/$LREL"; echo; cat "$staging/$rel"; echo; } | grep -v '^$' | sort -u > "$dst/$LREL.dsync.tmp" 2>/dev/null; urc=$?
			[ "$lm" -gt "${mtime:-0}" ] 2>/dev/null && mtime=$lm
			# accepted only when sort succeeded and no live entry went missing (a full card can leave a partial file)
			lcnt=$(grep -v '^$' "$dst/$LREL" 2>/dev/null | sort -u | wc -l | tr -d ' '); ucnt=$(grep -c . "$dst/$LREL.dsync.tmp" 2>/dev/null)
			if [ "$urc" = 0 ] && [ "${ucnt:-0}" -gt 0 ] && [ "${ucnt:-0}" -ge "${lcnt:-0}" ] 2>/dev/null && mv "$dst/$LREL.dsync.tmp" "$dst/$LREL" 2>/dev/null; then
				set_mtime "$dst/$LREL" "${mtime:-0}"
				printf 'UPDATE\t%s\t%s\n' "$(file_size "$dst/$LREL")" "$rel" >> "$bdir/ops.log"
				printf 'DONE\t%s\t%s\n' "$action" "$rel" >> "$jl"
			else
				rm -f "$dst/$LREL.dsync.tmp"; printf 'FAIL\t%s (union)\n' "$rel" >&2; rc=1
			fi
			continue
		fi
		# MOVE, not copy: staging and the card are one filesystem, so the transfer needs its own size
		# once, not twice (a 25 GB library asked a 29 GB card for 52 GB, 2026-09-21). cp only if the
		# move is refused (a staging dir on another mount).
		# a same-filesystem rename cannot change the size; only the cp fallback (another mount, a full card)
		# needs the landed bytes read back
		if mv "$staging/$rel" "$dst/$LREL.dsync.tmp" 2>/dev/null; then lsz=$ssz
		else cp "$staging/$rel" "$dst/$LREL.dsync.tmp" 2>/dev/null; lsz=$(file_size "$dst/$LREL.dsync.tmp"); fi
		if [ "$ssz" = "$lsz" ] && mv "$dst/$LREL.dsync.tmp" "$dst/$LREL" 2>/dev/null; then
			set_mtime "$dst/$LREL" "${mtime:-0}"
			op=UPDATE; [ "$bkstate" = none ] && op=ADD
			printf '%s\t%s\t%s\n' "$op" "$ssz" "$rel" >> "$bdir/ops.log"
			printf 'DONE\t%s\t%s\n' "$action" "$rel" >> "$jl"
		else
			rm -f "$dst/$LREL.dsync.tmp"; printf 'FAIL\t%s\n' "$rel" >&2; rc=1
		fi
	done < "$t.work"
	[ "$rc" = 0 ] && printf 'COMPLETE\n' >> "$jl"
	rm -f "$t" "$t.work"
	return $rc
}
apply_plan()  { _apply_plan new "$@"; }
resume_apply(){ _apply_plan resume "$@"; }

# ---- journal-status: did the last apply finish? ----
# COMPLETE, or "INCOMPLETE \t <rel>" naming the file it died on (a BEGIN with no DONE), or a bare
# INCOMPLETE if it stopped between files. Power loss mid-apply is what this is for.
journal_status() { # <backupdir>
	[ -f "$1/journal.log" ] || { echo "journal-status: no journal in $1" >&2; return 1; }
	awk -F"$TAB" -v OFS="$TAB" '
		$1=="BEGIN"    { fin=0; if (!($2 in seen)) { seen[$2]=1; order[++n]=$2 } pend[$2]=1; next }   # a BEGIN after a COMPLETE = a later pass that did not finish
		$1=="DONE"     { pend[$3]=0; next }
		$1=="COMPLETE" { fin=1; next }
		END {
			if (fin) { print "COMPLETE"; exit }
			for (i=1;i<=n;i++) if (pend[order[i]]) { print "INCOMPLETE", order[i]; exit }
			print "INCOMPLETE"
		}
	' "$1/journal.log"
}

# ---- resume-check: what still needs downloading ----
# A staged file counts as done when its size AND (when the plan carries one) its hash match the plan, so a
# half-downloaded file is re-fetched and a verified one is never fetched twice. Batched like _plan_rich:
# one ls for the planned rels, one md5sum for the ones whose size already matches (a size mismatch is
# already "not staged", no hash needed).
resume_check() { # <planfile> <staging>
	plan="$1"; staging="$2"
	t=$(tmpf)
	awk -F"$TAB" '$1=="take" && $4 != "" && $4 !~ /^\// && $4 != ".." && $4 !~ /^\.\.\// && $4 !~ /\/\.\.$/ && $4 !~ /\/\.\.\// { print "./" $4 }' "$plan" > "$t.rels"
	: > "$t.sz"; : > "$t.cand"; : > "$t.md5"
	if [ -s "$t.rels" ]; then
		( cd "$staging" 2>/dev/null && tr '\n' '\0' < "$t.rels" | xargs -0 ls -lnL 2>/dev/null ) > "$t.sz"
		awk -F"$TAB" '
			FILENAME==ARGV[1] { i=index($0," ./"); if (i) { split($0,a," "); sz[substr($0,i+3)]=a[5] } next }
			$1=="take" && $5 != "" && $5 != "-" && ($4 in sz) && sz[$4] == $3 { print "./" $4 }
		' "$t.sz" "$plan" > "$t.cand"
		[ -s "$t.cand" ] && ( cd "$staging" 2>/dev/null && tr '\n' '\0' < "$t.cand" | xargs -0 md5sum 2>/dev/null ) > "$t.md5"
	fi
	awk -F"$TAB" '
		FILENAME==ARGV[1] { i=index($0," ./"); if (i) { split($0,a," "); sz[substr($0,i+3)]=a[5] } next }
		FILENAME==ARGV[2] { h[substr($0,37)]=substr($0,1,32); next }
		$1=="take" {
			rel=$4
			if (rel == "" || rel ~ /^\// || rel == ".." || rel ~ /^\.\.\// || rel ~ /\/\.\.$/ || rel ~ /\/\.\.\//) next
			if (seen[rel]++) next                                                    # ask for each file once
			if (!(rel in sz))  { print rel; next }                                   # never downloaded
			if (sz[rel] != $3) { print rel; next }                                   # partial / wrong size
			if ($5 != "" && $5 != "-" && (!(rel in h) || h[rel] != $5)) print rel     # wrong bytes
		}
	' "$t.sz" "$t.md5" "$plan"
	rm -f "$t" "$t.rels" "$t.sz" "$t.cand" "$t.md5"
}

# ---- plan-need: the free space this plan REALLY needs, in KB ----
# Every planned byte lands on the card TWICE before the run ends: once downloaded into staging (which
# lives on the card so a drop is resumable) and once applied, and staging is only cleared when the whole
# run finishes. On top of that each file the plan REPLACES is copied into the backup dir first. Budget
# this number, never the plan's byte total -- a 1.4 GB plan onto 1.7 GB free passed the old check and
# then filled the card mid-apply. With <dst> the backup allowance is exact; without it (the peer's card,
# whose contents we cannot stat) it is the staged+applied pair only, so the caller should keep its own
# slack on top.
plan_need() { # <planfile> [dst] : KB that must be free on the receiving card
	pn="$1"; pndst="${2:-}"
	nt=$(tmpf); : > "$nt.sz"
	if [ -n "$pndst" ] && [ -d "$pndst" ]; then
		awk -F"$TAB" '$1=="take" && $4 != "" && $4 !~ /^\// && $4 != ".." && $4 !~ /^\.\.\// && $4 !~ /\/\.\.$/ && $4 !~ /\/\.\.\// { print "./" $4 }' "$pn" > "$nt.rels"
		[ -s "$nt.rels" ] && ( cd "$pndst" 2>/dev/null && tr '\n' '\0' < "$nt.rels" | xargs -0 ls -lnL 2>/dev/null ) > "$nt.sz"
	fi
	awk -F"$TAB" '
		FILENAME==ARGV[1] { i=index($0," ./"); if (i) { split($0,a," "); bk += a[5] } next }   # files that will be backed up
		$1=="take" && $4 != "" && !seen[$4]++ { pl += $3; if ($3+0 > mx) mx = $3+0 }
		END { sl = 209715200; if (mx > sl) sl = mx; if (sl > pl) sl = pl; print int((pl + bk + sl + 1023) / 1024) }   # plan + backups + one bundle chunk (a single file can exceed the cap)
	' "$nt.sz" "$pn"
	rm -f "$nt" "$nt.rels" "$nt.sz"
}

# ---- restore: backup-first, so it can never lose data and is itself undoable ----
# Replaces the old undo, which guessed. Its ADD branch decided "did the user change this since the sync?"
# by SIZE -- a battery save is fixed-size, so a save played since the sync looked untouched and was
# deleted; its UPDATE branch put the pre-sync copy back unconditionally, destroying progress made after
# the sync. Both bugs lived in the guessing, so the guessing is gone:
#   1. copy the CURRENT state of every file the sync touched into a NEW timestamped snapshot, THEN
#   2. put the pre-sync originals back (an ADD had no original -- putting "nothing" back = remove it).
# Because step 1 always runs first, whatever step 2 replaces or removes is still on the card in the new
# snapshot, and restoring THAT snapshot undoes the restore. Nothing is ever destroyed.
# The file list comes from ops.log, not journal.log: ops.log names exactly what was CHANGED (a file that
# was backed up but never written is untouched, so it must not be "restored"), and it carries the
# pre-state each rel needs. Prints the new snapshot dir on stdout as its first line.
restore() { # <dst> <backupdir> [file of rels: restore ONLY these]
	dst="$1"; bdir="$2"; rsel="${3:-}"
	[ -f "$bdir/ops.log" ] || { echo "restore: no ops.log in $bdir" >&2; return 1; }
	root=$(dirname "$bdir")
	ts=$(date +%Y%m%d-%H%M%S); n=0
	while [ -e "$root/$ts" ]; do n=$((n+1)); ts="$(date +%Y%m%d-%H%M%S)-$n"; done
	new="$root/$ts"
	mkdir -p "$new" || { echo "restore: cannot create $new" >&2; return 1; }
	: > "$new/ops.log"; : > "$new/journal.log"
	printf '%s\n' "$new"
	t=$(tmpf)
	# one line per rel (a crash-resumed apply can log a rel twice, and snapshotting it twice would
	# overwrite the snapshot with the already-restored file)
	if [ -n "$rsel" ] && [ -f "$rsel" ]; then   # a chosen subset (Dan 2026-09-22: undo one save, not the whole sync)
		awk -F"$TAB" -v OFS="$TAB" 'FILENAME==ARGV[1] { k[$0]=1; next } !seen[$3]++ && ($3 in k) { print $1, $3 }' "$rsel" "$bdir/ops.log" > "$t.work"
	else
		awk -F"$TAB" -v OFS="$TAB" '!seen[$3]++ { print $1, $3 }' "$bdir/ops.log" > "$t.work"
	fi
	rc=0; rdone=0; rmiss=0
	while IFS="$TAB" read -r op rel; do
		[ -n "$rel" ] || continue
		case "$rel" in /*|..|../*|*/..|*/../*) printf 'UNSAFE\t%s\n' "$rel" >&2; continue ;; esac
		local_rel "$rel"
		printf 'BEGIN\t%s\n' "$rel" >> "$new/journal.log"
		# 1. snapshot what is there NOW (verified), recorded in the new snapshot's own ops.log in the same
		#    vocabulary, so restoring the new snapshot is the exact inverse of this restore
		if [ -e "$dst/$LREL" ]; then
			cmt=$(file_mtime "$dst/$LREL")
			if ! mkdir -p "$new/$(dirname "$rel")" 2>/dev/null \
			   || ! cp "$dst/$LREL" "$new/$rel" 2>/dev/null \
			   || [ "$(file_size "$dst/$LREL")" != "$(file_size "$new/$rel")" ]; then
				rm -f "$new/$rel"; printf 'FAIL\t%s (snapshot)\n' "$rel" >&2; rc=1; rmiss=$((rmiss+1)); continue   # never touch what we could not save
			fi
			set_mtime "$new/$rel" "$cmt"
			printf 'UPDATE\t%s\t%s\n' "$(file_size "$new/$rel")" "$rel" >> "$new/ops.log"
		else
			printf 'ADD\t0\t%s\n' "$rel" >> "$new/ops.log"    # nothing here now: restoring THIS snapshot removes it again
		fi
		# 2. put the pre-sync state back
		case "$op" in
		UPDATE)  # there is a pre-sync copy: atomic put-back (tmp + verify + rename), original mtime
			if [ -e "$bdir/$rel" ]; then
				mkdir -p "$dst/$(dirname "$LREL")"
				cp "$bdir/$rel" "$dst/$LREL.dsync.tmp" 2>/dev/null
				if [ "$(file_size "$bdir/$rel")" = "$(file_size "$dst/$LREL.dsync.tmp")" ] && mv "$dst/$LREL.dsync.tmp" "$dst/$LREL" 2>/dev/null; then
					set_mtime "$dst/$LREL" "$(file_mtime "$bdir/$rel")"
					printf 'DONE\trestore\t%s\n' "$rel" >> "$new/journal.log"; rdone=$((rdone+1))
				else
					rm -f "$dst/$LREL.dsync.tmp"; printf 'RESTORE-FAIL\t%s\n' "$rel" >&2; rc=1; rmiss=$((rmiss+1))
				fi
			else
				printf 'RESTORE-MISS\t%s\n' "$rel" >&2; rc=1; rmiss=$((rmiss+1))   # backup gone: leave the live file alone, never truncate it
			fi ;;
		ADD)     # the sync added this file; before it there was nothing. Its current bytes are in $new.
			rm -f "$dst/$LREL" 2>/dev/null
			if [ -e "$dst/$LREL" ]; then printf 'RESTORE-FAIL\t%s (remove)\n' "$rel" >&2; rc=1; rmiss=$((rmiss+1)); continue; fi
			d=$(dirname "$LREL")
			while [ "$d" != "." ] && [ "$d" != "/" ]; do
				rmdir "$dst/$d" 2>/dev/null || break
				d=$(dirname "$d")
			done
			printf 'DONE\tremove\t%s\n' "$rel" >> "$new/journal.log"; rdone=$((rdone+1)) ;;
		esac
	done < "$t.work"
	[ "$rc" = 0 ] && printf 'COMPLETE\n' >> "$new/journal.log"
	# the caller has to tell "restored" from "restored what it could": rc says which, this names the
	# counts behind it. stderr, never stdout -- stdout's first line is the snapshot dir the caller reads
	printf 'RESTORED\t%s\t%s\n' "$rdone" "$rmiss" >&2
	rm -f "$t" "$t.work"
	return $rc
}
# undo: kept as the old name for the v1 caller; same backup-first restore, no guessing.
undo() { restore "$@"; }

# ---- pick tree (Device Sync send): consoles, their games, and the files a game brings along ----
# "1) Game Boy Color (GBC)" -> name "Game Boy Color", tag "GBC". Saves live at Saves/<tag>/<rom file>.sav
# and states at .userdata/shared/<tag>-<core>/<rom stem>.st0..9 (MinUI convention), so a game's stem
# finds both. A directory under a console (a multi-disc set) counts as one game.
sys_tag()  { n=${1##*/}; case "$n" in *"("*")") t=${n##*(}; echo "${t%)}" ;; *) echo "" ;; esac; }
sys_name() { n=${1##*/}; n=${n%% (*}; echo "${n#*) }"; }
systems() { # <card> : rel \t name \t tag \t games \t KB, one line per console folder with at least one game
	card="$1"
	for d in "$card"/Roms/*/; do
		[ -d "$d" ] || continue
		d=${d%/}; rel=${d#"$card"/}
		n=0; for g in "$d"/*; do [ -e "$g" ] || continue; case "${g##*/}" in .*) continue ;; esac; n=$((n+1)); done
		[ "$n" -gt 0 ] || continue
		kb=$(du -sk "$d" 2>/dev/null | cut -f1)
		printf '%s\t%s\t%s\t%s\t%s\n' "$rel" "$(sys_name "$d")" "$(sys_tag "$d")" "$n" "${kb:-0}"
	done
}
games() { # <card> <console rel> : rel \t name \t KB \t save mtime (0 = no save) \t states
	card="$1"; sys="$2"; tag=$(sys_tag "$sys")
	for g in "$card/$sys"/*; do
		[ -e "$g" ] || continue; f=${g##*/}; case "$f" in .*) continue ;; esac
		stem=${f%.*}; [ -d "$g" ] && stem=$f
		kb=$(du -sk "$g" 2>/dev/null | cut -f1)
		sm=0; for s in "$card/Saves/$tag/$stem".*; do [ -f "$s" ] || continue
			case "$s" in *.dsync.tmp|*.dsync.part) continue ;; esac    # our own half-written scratch, not a save
			m=$(file_mtime "$s"); [ "${m:-0}" -gt "$sm" ] && sm=$m; done
		st=0; for s in "$card"/.userdata/shared/"$tag"-*/"$stem".st[0-9]; do [ -f "$s" ] && st=$((st+1)); done
		printf '%s\t%s\t%s\t%s\t%s\n' "$sys/$f" "$stem" "${kb:-0}" "$sm" "$st"
	done
}
game_files() { # <card> <game rel> <saves 1|0> <rom 1|0> : the relpaths that travel with this game
	card="$1"; rel="$2"; sys=${rel%/*}; f=${rel##*/}; tag=$(sys_tag "$sys")
	stem=${f%.*}; [ -d "$card/$rel" ] && stem=$f
	[ "$4" = 1 ] && [ -e "$card/$rel" ] && printf '%s\n' "$rel"
	if [ "$3" = 1 ]; then
		# never send our own half-written scratch along with the game
		for s in "$card/Saves/$tag/$stem".*; do [ -f "$s" ] || continue
			case "$s" in *.dsync.tmp|*.dsync.part) continue ;; esac; printf '%s\n' "${s#"$card"/}"; done
		for s in "$card"/.userdata/shared/"$tag"-*/"$stem".*; do [ -f "$s" ] || continue
			case "$s" in *.dsync.tmp|*.dsync.part) continue ;; esac; printf '%s\n' "${s#"$card"/}"; done
	fi
	return 0
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
	plan-rich) plan_rich "$@" ;;
	plan-summary) plan_summary "$@" ;;
	merge)     merge_manifests "$@" ;;
	merge-summary) merge_summary "$@" ;;
	apply-net) apply_net "$@" ;;
	apply-plan)     apply_plan "$@" ;;
	resume-apply)   resume_apply "$@" ;;
	journal-status) journal_status "$@" ;;
	resume-check)   resume_check "$@" ;;
	plan-need)      plan_need "$@" ;;
	sweep-tmp)      sweep_tmp "$@" ;;
	restore)   restore "$@" ;;
	undo)      undo "$@" ;;
	prune)     prune "$@" ;;
	classify)  classify "$@" ;;
	systems)   systems "$@" ;;
	games)     games "$@" ;;
	game-files) game_files "$@" ;;
	*) echo "usage: sync-engine.sh {manifest|plan|apply|delta|plan-net|plan-rich|plan-summary|merge|merge-summary|apply-net|apply-plan|resume-apply|journal-status|resume-check|plan-need|sweep-tmp|restore|undo|prune|classify|systems|games|game-files} ..." >&2; exit 2 ;;
esac
