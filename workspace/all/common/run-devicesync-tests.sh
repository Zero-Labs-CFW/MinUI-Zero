#!/bin/sh
# Host test harness for the Device Sync engine. Zero hardware. Two scenarios:
#   1. dir-to-dir (host merge): manifest+bytes from a local src tree.
#   2. networked: sender MANIFEST + downloaded bytes in a staging dir (wget does NOT preserve mtime),
#      proving the manifest's mtime is authoritative for the merge AND is stamped on the applied file.
# Both prove: never-lose-a-save (backup + exact undo), never-delete, never-overwrite-a-ROM,
# clock-skew-safe merge, atomic writes, filenames with spaces.
# Run: make test-devicesync
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
ENGINE="$ROOT/skeleton/EXTRAS/Tools/tg5040/Device Sync.pak/sync-engine.sh"
[ -f "$ENGINE" ] || { echo "engine not found: $ENGINE" >&2; exit 2; }
E() { sh "$ENGINE" "$@"; }
TAB=$(printf '\t')
mt() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got [$2] want [$3])"; fi; }
has()   { if printf '%s\n' "$2" | grep -qF "$1"; then ok "plan: $1"; else bad "plan missing: $1"; fi; }
nohas() { if printf '%s\n' "$2" | grep -qF "$1"; then bad "plan should NOT have: $1"; else ok "plan omits: $1"; fi; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/dsync-test.XXXXXX")
mk() { mkdir -p "$1/$(dirname "$2")"; printf '%s' "$3" > "$1/$2"; [ $# -ge 4 ] && touch -t "$4" "$1/$2"; }

build_trees() { # <A> <B> : the standard matrix exercising every merge rule
	A="$1"; B="$2"; mkdir -p "$A" "$B"
	mk "$A" "Roms/GBA/game1.gba" "IDENTICAL-ROM"        ; mk "$B" "Roms/GBA/game1.gba" "IDENTICAL-ROM"      # SKIP
	mk "$A" "Roms/GBA/game2.gba" "NEW-ROM-ONLY-IN-A"                                                        # ADD
	mk "$A" "Roms/GBA/game3.gba" "ROM-VERSION-AAAA"     ; mk "$B" "Roms/GBA/game3.gba" "ROM-VERSION-B"      # SKIP (ROM present by name)
	mk "$A" "Roms/Game Boy Advance/Metroid Fusion (USA).gba" "SPACEY"                                       # ADD (spaces)
	mk "$A" "Saves/GBA/save1.srm" "NEW-SAVE-ONLY-IN-A"                                                      # ADD
	mk "$A" "Saves/GBA/save2.srm" "A-IS-NEWER-CONTENT" 202602010000 ; mk "$B" "Saves/GBA/save2.srm" "B-OLD-CONTENT" 202601010000  # UPDATE
	mk "$A" "Saves/GBA/save3.srm" "A-OLD-CONTENT" 202601010000      ; mk "$B" "Saves/GBA/save3.srm" "B-IS-NEWER-CONTENT" 202602010000 # KEEP-LOCAL
	mk "$A" "Saves/GBA/save4.srm" "SAME-SAVE" 202601010000 ; mk "$B" "Saves/GBA/save4.srm" "SAME-SAVE" 202601010000  # SKIP (identical: same size+mtime)
	mk "$B" "Saves/GBA/localonly.srm" "ONLY-ON-B-NEVER-DELETE"                                              # untouched
}

assert_applied() { # <B> <BK> : the shared post-apply safety assertions
	B="$1"; BK="$2"
	check "game2 added"              "$(cat "$B/Roms/GBA/game2.gba")"                              "NEW-ROM-ONLY-IN-A"
	check "spacey rom added"         "$(cat "$B/Roms/Game Boy Advance/Metroid Fusion (USA).gba")" "SPACEY"
	check "ROM conflict kept local"  "$(cat "$B/Roms/GBA/game3.gba")"                              "ROM-VERSION-B"
	check "save1 added"              "$(cat "$B/Saves/GBA/save1.srm")"                             "NEW-SAVE-ONLY-IN-A"
	check "save2 updated to A"       "$(cat "$B/Saves/GBA/save2.srm")"                             "A-IS-NEWER-CONTENT"
	check "save2 loser BACKED UP"    "$(cat "$BK/Saves/GBA/save2.srm")"                            "B-OLD-CONTENT"
	check "save3 kept local (newer)" "$(cat "$B/Saves/GBA/save3.srm")"                             "B-IS-NEWER-CONTENT"
	check "save4 untouched"          "$(cat "$B/Saves/GBA/save4.srm")"                             "SAME-SAVE"
	check "B-only file NOT deleted"  "$(cat "$B/Saves/GBA/localonly.srm")"                         "ONLY-ON-B-NEVER-DELETE"
	if ls "$B"/Roms/GBA/*.dsync.tmp >/dev/null 2>&1; then bad "temp file left behind"; else ok "no temp files left"; fi
}

######################################################################
echo "########## SCENARIO 1: dir-to-dir ##########"
A="$WORK/s1/incoming"; B="$WORK/s1/local"; BK="$WORK/s1/backup/20260903-1200"; REF="$WORK/s1/ref"
build_trees "$A" "$B"; cp -R "$B" "$REF"

echo "== manifest format (5 cols; rom hash '-'; save hash real) =="
M=$(E manifest "$A")
NF=$(printf '%s\n' "$M" | head -1 | awk -F"$TAB" '{print NF}')
check "manifest has 5 columns" "$NF" "5"
ROMHASH=$(printf '%s\n' "$M" | grep 'game1.gba' | cut -f5)
check "rom hash is '-'" "$ROMHASH" "-"
# no content hash any more: identity is size (col 2) + mtime (col 3), hash column is always "-"
SAVEHASH=$(printf '%s\n' "$M" | grep 'save4.srm' | cut -f5)
check "save hash column is '-' (hashless)" "$SAVEHASH" "-"
SAVEMT=$(printf '%s\n' "$M" | grep 'save4.srm' | cut -f3)
if [ -n "$SAVEMT" ] && [ "$SAVEMT" != "0" ]; then ok "save carries an mtime ($SAVEMT)"; else bad "save mtime missing"; fi

echo "== plan =="
P=$(E plan "$A" "$B"); printf '%s\n' "$P" | sed 's/^/    /'
has  "ADD${TAB}Roms/GBA/game2.gba" "$P"
has  "SKIP${TAB}Roms/GBA/game1.gba" "$P"
has  "SKIP${TAB}Roms/GBA/game3.gba" "$P"   # ROM present by name -> SKIP (existence only, never re-copied)
has  "ADD${TAB}Roms/Game Boy Advance/Metroid Fusion (USA).gba" "$P"
has  "UPDATE${TAB}Saves/GBA/save2.srm" "$P"
has  "KEEP-LOCAL${TAB}Saves/GBA/save3.srm" "$P"
has  "SKIP${TAB}Saves/GBA/save4.srm" "$P"
nohas "localonly.srm" "$P"

echo "== apply =="; E apply "$A" "$B" "$BK"; assert_applied "$B" "$BK"
echo "== undo (the v1 name, now the backup-first restore) =="
E undo "$B" "$BK" >/dev/null
if diff -r "$REF" "$B" >/dev/null 2>&1; then ok "undo restored EXACT pre-sync state"; else bad "undo mismatch"; diff -r "$REF" "$B" | sed 's/^/    /'; fi

######################################################################
echo "########## SCENARIO 2: networked (manifest + staged bytes, wget-style no-mtime) ##########"
A2="$WORK/s2/sender"; B2="$WORK/s2/local"; ST="$WORK/s2/staging"; BK2="$WORK/s2/backup/20260904-0900"; REF2="$WORK/s2/ref"
build_trees "$A2" "$B2"; cp -R "$B2" "$REF2"; mkdir -p "$ST"
MF="$WORK/s2/sender.manifest"; E manifest "$A2" > "$MF"

echo "== delta (what the receiver must download) =="
DL=$(E delta "$MF" "$B2"); printf '%s\n' "$DL" | sed 's/^/    /'
has "Roms/GBA/game2.gba" "$DL"
has "Saves/GBA/save1.srm" "$DL"
has "Saves/GBA/save2.srm" "$DL"
has "Roms/Game Boy Advance/Metroid Fusion (USA).gba" "$DL"
nohas "game3.gba" "$DL"   # ROM present by name: SKIP, never downloaded
nohas "save3.srm" "$DL"   # KEEP-LOCAL: not downloaded
nohas "save4.srm" "$DL"   # identical: not downloaded

echo "== simulate wget download into staging (mtime deliberately WRONG = now) =="
printf '%s\n' "$DL" | while IFS= read -r rel; do
	[ -n "$rel" ] || continue
	mkdir -p "$ST/$(dirname "$rel")"; cp "$A2/$rel" "$ST/$rel"; touch "$ST/$rel"   # touch = clobber mtime to now
done

echo "== apply-net (manifest mtime must win over staging's now-mtime) =="
E apply-net "$MF" "$ST" "$B2" "$BK2"
assert_applied "$B2" "$BK2"
check "save2 mtime = sender's (manifest authoritative)" "$(mt "$B2/Saves/GBA/save2.srm")" "$(mt "$A2/Saves/GBA/save2.srm")"
check "save1 mtime = sender's (manifest authoritative)" "$(mt "$B2/Saves/GBA/save1.srm")" "$(mt "$A2/Saves/GBA/save1.srm")"

echo "== undo (networked) =="
E undo "$B2" "$BK2" >/dev/null
if diff -r "$REF2" "$B2" >/dev/null 2>&1; then ok "undo restored EXACT pre-sync state"; else bad "undo mismatch"; diff -r "$REF2" "$B2" | sed 's/^/    /'; fi

######################################################################
echo "########## SCENARIO 3: safety failure injection (the review's findings) ##########"

echo "== A: a failed/blocked backup must NOT overwrite the local save =="
A3="$WORK/s3a/sender"; B3="$WORK/s3a/local"; mkdir -p "$A3" "$B3"
mk "$A3" "Saves/GBA/x.srm" "SENDER-NEW" 202602010000; mk "$B3" "Saves/GBA/x.srm" "LOCAL-OLD" 202601010000
BADBK="$WORK/s3a/badbk"; mkdir -p "$BADBK"; chmod 000 "$BADBK"
E apply "$A3" "$B3" "$BADBK/sub" 2>/dev/null
check "A: backup-fail leaves local save intact" "$(cat "$B3/Saves/GBA/x.srm")" "LOCAL-OLD"
chmod 755 "$BADBK"

echo "== B: undo with a missing backup must not truncate the live save =="
A3b="$WORK/s3b/sender"; B3b="$WORK/s3b/local"; BK3b="$WORK/s3b/bk"; mkdir -p "$A3b" "$B3b"
mk "$A3b" "Saves/GBA/y.srm" "Y-NEW" 202602010000; mk "$B3b" "Saves/GBA/y.srm" "Y-OLD" 202601010000
E apply "$A3b" "$B3b" "$BK3b"
rm -f "$BK3b/Saves/GBA/y.srm"
E undo "$B3b" "$BK3b" >/dev/null 2>&1
check "B: undo w/ lost backup leaves save intact (not truncated)" "$(cat "$B3b/Saves/GBA/y.srm")" "Y-NEW"

echo "== C: unsafe manifest paths (.. and absolute) are rejected =="
MFC="$WORK/s3c.manifest"; DSTC="$WORK/s3c/local"; STC="$WORK/s3c/staging"; mkdir -p "$DSTC" "$STC/Saves/GBA"
printf 'Saves/GBA/ok.srm\t5\t1700000000\tsave\t-\n../evil.srm\t4\t1700000000\tsave\t-\n/etc/evil\t4\t1700000000\tsave\t-\n' > "$MFC"
DLC=$(E delta "$MFC" "$DSTC" 2>/dev/null)
has "Saves/GBA/ok.srm" "$DLC"
nohas "evil" "$DLC"
printf OK123 > "$STC/Saves/GBA/ok.srm"
E apply-net "$MFC" "$STC" "$DSTC" "$WORK/s3c/bk" 2>/dev/null
check "C: ../evil not created outside dst" "$([ -e "$WORK/s3c/evil.srm" ] && echo LEAK || echo safe)" "safe"

echo "== D: a reused backup dir is refused (protects the prior snapshot) =="
A3d="$WORK/s3d/sender"; B3d="$WORK/s3d/local"; BK3d="$WORK/s3d/bk"; mkdir -p "$A3d" "$B3d"
mk "$A3d" "Saves/GBA/z.srm" "Z1"; E apply "$A3d" "$B3d" "$BK3d"; OPS1=$(cat "$BK3d/ops.log")
mk "$A3d" "Saves/GBA/z2.srm" "Z2"
E apply "$A3d" "$B3d" "$BK3d" 2>/dev/null; RC=$?
check "D: reused bdir refused (nonzero rc)" "$([ "$RC" != "0" ] && echo refused || echo allowed)" "refused"
check "D: prior snapshot ops.log intact" "$(cat "$BK3d/ops.log")" "$OPS1"

echo "== E: undo restores the ORIGINAL mtime, not undo's cp time =="
A3e="$WORK/s3e/sender"; B3e="$WORK/s3e/local"; BK3e="$WORK/s3e/bk"; mkdir -p "$A3e" "$B3e"
mk "$A3e" "Saves/GBA/m.srm" "M-NEW" 202602010000; mk "$B3e" "Saves/GBA/m.srm" "M-OLD" 202601010000
OMT=$(mt "$B3e/Saves/GBA/m.srm"); E apply "$A3e" "$B3e" "$BK3e"; E undo "$B3e" "$BK3e" >/dev/null
check "E: undo restored original content" "$(cat "$B3e/Saves/GBA/m.srm")" "M-OLD"
check "E: undo restored original mtime"   "$(mt "$B3e/Saves/GBA/m.srm")" "$OMT"

echo "== F: restore of an ADD is backup-first (it never guesses whether the user touched it) =="
# The old undo asked "is this still the size I wrote?" to decide whether to delete an added file. A
# battery save is FIXED SIZE, so a save played since the sync answered "yes" and was deleted. The rule
# now: snapshot the current state first, then put the device back -- so removing is always recoverable.
A3f="$WORK/s3f/sender"; B3f="$WORK/s3f/local"; BK3f="$WORK/s3f/backups/20260101-0000"; mkdir -p "$A3f" "$B3f"
mk "$A3f" "Saves/GBA/new1.srm" "ADDED"; mk "$A3f" "Saves/GBA/new2.srm" "ADDED2"
E apply "$A3f" "$B3f" "$BK3f"
printf 'USER-EDITED-BIGGER' > "$B3f/Saves/GBA/new1.srm"
SNAP3f=$(E restore "$B3f" "$BK3f" 2>/dev/null)
check "F: restore put the device back (added file gone)" "$([ -e "$B3f/Saves/GBA/new1.srm" ] && echo present || echo removed)" "removed"
check "F: restore removed the untouched ADD too"         "$([ -e "$B3f/Saves/GBA/new2.srm" ] && echo present || echo removed)" "removed"
check "F: the user's post-sync edit is KEPT in the new snapshot" "$(cat "$SNAP3f/Saves/GBA/new1.srm" 2>/dev/null)" "USER-EDITED-BIGGER"
E restore "$B3f" "$SNAP3f" >/dev/null 2>&1
check "F: the restore is itself undoable (edit came back)" "$(cat "$B3f/Saves/GBA/new1.srm" 2>/dev/null)" "USER-EDITED-BIGGER"

######################################################################
echo "########## SCENARIO 4: push mode (DS_MODE=push -- directional send, sender wins) ##########"
A4="$WORK/s4/sender"; B4="$WORK/s4/local"; BK4="$WORK/s4/bk"; build_trees "$A4" "$B4"
MF4="$WORK/s4.manifest"; DS_MODE=push sh "$ENGINE" manifest "$A4" > "$MF4"
P4=$(DS_MODE=push sh "$ENGINE" plan-net "$MF4" "$B4"); printf '%s\n' "$P4" | sed 's/^/    /'
has "UPDATE${TAB}Saves/GBA/save2.srm" "$P4"       # sender newer -> UPDATE
has "UPDATE${TAB}Saves/GBA/save3.srm" "$P4"       # local newer, but PUSH -> sender still wins
has "SKIP${TAB}Saves/GBA/save4.srm" "$P4"         # identical -> still skipped (no needless copy)
has "SKIP${TAB}Roms/GBA/game3.gba" "$P4"  # ROM present by name -> SKIP, never overwritten
ST4="$WORK/s4/staging"; mkdir -p "$ST4"
DS_MODE=push sh "$ENGINE" delta "$MF4" "$B4" | while IFS= read -r rel; do [ -n "$rel" ] || continue; mkdir -p "$ST4/$(dirname "$rel")"; cp "$A4/$rel" "$ST4/$rel"; done
DS_MODE=push sh "$ENGINE" apply-net "$MF4" "$ST4" "$B4" "$BK4"
check "push: local-newer save OVERWRITTEN by sender" "$(cat "$B4/Saves/GBA/save3.srm")"        "A-OLD-CONTENT"
check "push: the overwritten local save is backed up" "$(cat "$BK4/Saves/GBA/save3.srm")"      "B-IS-NEWER-CONTENT"
check "push: identical save left untouched"           "$(cat "$B4/Saves/GBA/save4.srm")"       "SAME-SAVE"
check "push: ROM conflict still kept local"           "$(cat "$B4/Roms/GBA/game3.gba")"        "ROM-VERSION-B"
check "push: local-only file NOT deleted"             "$(cat "$B4/Saves/GBA/localonly.srm")"   "ONLY-ON-B-NEVER-DELETE"

######################################################################
echo "########## SCENARIO 5: ask mode (DS_MODE=ask -- same game, different save = CONFLICT the user resolves) ##########"
# The Mario Golf case: a save that differs on both devices is NEVER blindly overwritten. It becomes a
# CONFLICT; apply touches it only if the user approved that rel (DS_TAKE). New saves still auto-apply.
A5="$WORK/s5/sender"; B5="$WORK/s5/local"; build_trees "$A5" "$B5"
MF5="$WORK/s5.manifest"; E manifest "$A5" > "$MF5"
P5=$(DS_MODE=ask sh "$ENGINE" plan-net "$MF5" "$B5"); printf '%s\n' "$P5" | sed 's/^/    /'
has   "ADD${TAB}Saves/GBA/save1.srm" "$P5"        # new save -> auto ADD (no prompt)
has   "CONFLICT${TAB}Saves/GBA/save2.srm" "$P5"   # differs on both -> CONFLICT, not UPDATE
has   "CONFLICT${TAB}Saves/GBA/save3.srm" "$P5"   # differs on both (other direction) -> CONFLICT too
has   "SKIP${TAB}Saves/GBA/save4.srm" "$P5"       # identical -> skipped
nohas "UPDATE${TAB}Saves/GBA/save2.srm" "$P5"     # ask mode NEVER silently overwrites a differing save
nohas "UPDATE${TAB}Saves/GBA/save3.srm" "$P5"

# stage the delta (ADD + all CONFLICTs are downloaded; only approved conflicts get applied)
ST5="$WORK/s5/staging"; mkdir -p "$ST5"
DL5=$(DS_MODE=ask sh "$ENGINE" delta "$MF5" "$B5")
printf '%s\n' "$DL5" | while IFS= read -r rel; do [ -n "$rel" ] || continue; mkdir -p "$ST5/$(dirname "$rel")"; cp "$A5/$rel" "$ST5/$rel"; done
has "Saves/GBA/save2.srm" "$DL5"                  # conflicts ARE downloaded (so an approval can apply instantly)
nohas "Saves/GBA/save4.srm" "$DL5"                # identical file never downloaded

# user resolves: TAKE THEIRS for save3, KEEP MINE for save2
TAKE5="$WORK/s5.take"; printf 'Saves/GBA/save3.srm\n' > "$TAKE5"
BK5="$WORK/s5/bk"; DS_MODE=ask DS_TAKE="$TAKE5" sh "$ENGINE" apply-net "$MF5" "$ST5" "$B5" "$BK5"
check "ask: new save auto-added"                 "$(cat "$B5/Saves/GBA/save1.srm")"   "NEW-SAVE-ONLY-IN-A"
check "ask: KEEP MINE conflict left untouched"   "$(cat "$B5/Saves/GBA/save2.srm")"   "B-OLD-CONTENT"
check "ask: TAKE THEIRS conflict overwritten"    "$(cat "$B5/Saves/GBA/save3.srm")"   "A-OLD-CONTENT"
check "ask: the taken loser is backed up"        "$(cat "$BK5/Saves/GBA/save3.srm")"  "B-IS-NEWER-CONTENT"
check "ask: un-taken conflict NOT backed up"     "$([ -e "$BK5/Saves/GBA/save2.srm" ] && echo yes || echo no)" "no"
check "ask: ROM conflict still kept local"       "$(cat "$B5/Roms/GBA/game3.gba")"    "ROM-VERSION-B"

# KEEP MINE for everything (empty DS_TAKE): no save the user has is ever changed, ADDs still apply
A5b="$WORK/s5b/sender"; B5b="$WORK/s5b/local"; build_trees "$A5b" "$B5b"
MF5b="$WORK/s5b.manifest"; E manifest "$A5b" > "$MF5b"
ST5b="$WORK/s5b/staging"; mkdir -p "$ST5b"
DS_MODE=ask sh "$ENGINE" delta "$MF5b" "$B5b" | while IFS= read -r rel; do [ -n "$rel" ] || continue; mkdir -p "$ST5b/$(dirname "$rel")"; cp "$A5b/$rel" "$ST5b/$rel"; done
TAKE5b="$WORK/s5b.take"; : > "$TAKE5b"
BK5b="$WORK/s5b/bk"; DS_MODE=ask DS_TAKE="$TAKE5b" sh "$ENGINE" apply-net "$MF5b" "$ST5b" "$B5b" "$BK5b"
check "ask (keep-mine-all): save2 untouched"     "$(cat "$B5b/Saves/GBA/save2.srm")"  "B-OLD-CONTENT"
check "ask (keep-mine-all): save3 untouched"     "$(cat "$B5b/Saves/GBA/save3.srm")"  "B-IS-NEWER-CONTENT"
check "ask (keep-mine-all): new save still added" "$(cat "$B5b/Saves/GBA/save1.srm")" "NEW-SAVE-ONLY-IN-A"

######################################################################
echo "########## SCENARIO 6: Customize categories (saves conflict-protected; configs/recents take sender) ##########"
NET="$ROOT/skeleton/EXTRAS/Tools/tg5040/Device Sync.pak/sync-net.sh"
# classify the real card paths the Customize picker will export
check "classify: save state -> save"  "$(E classify '.userdata/shared/GB-gambatte/Mario.st0')"    "save"
check "classify: Syncthing conflict copy -> other" "$(E classify 'Saves/GBA/x.sav.sync-conflict-20250910-155402-GE6CEHW')" "other"
check "classify: recent.txt -> other (never synced)" "$(E classify '.userdata/shared/.minui/recent.txt')"       "other"
check "classify: favorites.txt -> favorite" "$(E classify '.userdata/shared/.minui/favorites.txt')" "favorite"
check "classify: game cfg -> config"  "$(E classify '.userdata/tg5040/GB-gambatte/Mario.cfg')"    "config"

A6="$WORK/s6/sender"; B6="$WORK/s6/local"; mkdir -p "$A6" "$B6"
# identity is size+mtime now (no hash): a file changed on both devices has DISTINCT mtimes, which is
# how real saves differ. Same size is fine (fixed-size SRAM is common) -- the mtime tells them apart.
mk "$A6" "Saves/GBC/Mario Golf.sav" "A-CHAR" 202602010000 ; mk "$B6" "Saves/GBC/Mario Golf.sav" "B-CHAR" 202601010000  # save -> CONFLICT
mk "$A6" ".userdata/shared/GB-gambatte/Mario.st0" "A-STATE" 202602010000 ; mk "$B6" ".userdata/shared/GB-gambatte/Mario.st0" "B-STATE" 202601010000  # state -> CONFLICT
mk "$A6" ".userdata/tg5040/GB-gambatte/Mario.cfg" "A-CFG" 202602010000   ; mk "$B6" ".userdata/tg5040/GB-gambatte/Mario.cfg" "B-CFG" 202601010000    # config -> UPDATE (sender/newer wins)
mk "$A6" ".userdata/shared/.minui/recent.txt" "A-RECENT" 202602010000    ; mk "$B6" ".userdata/shared/.minui/recent.txt" "B-RECENT" 202601010000    # recent -> UPDATE (sender/newer wins)
MF6="$WORK/s6.manifest"; E manifest "$A6" > "$MF6"
P6=$(DS_MODE=ask sh "$ENGINE" plan-net "$MF6" "$B6"); printf '%s\n' "$P6" | sed 's/^/    /'
has   "CONFLICT${TAB}Saves/GBC/Mario Golf.sav" "$P6"                       # save differs -> conflict (protected)
has   "CONFLICT${TAB}.userdata/shared/GB-gambatte/Mario.st0" "$P6"         # state differs -> conflict (protected)
has   "UPDATE${TAB}.userdata/tg5040/GB-gambatte/Mario.cfg" "$P6"           # config differs -> sender wins, no prompt
nohas "recent.txt" "$P6"                                                  # Recently Played never syncs
nohas "CONFLICT${TAB}.userdata/tg5040/GB-gambatte/Mario.cfg" "$P6"        # a config is NEVER a conflict prompt

# apply keeping mine on all save conflicts (empty DS_TAKE): saves+states untouched; config+recents replaced
ST6="$WORK/s6/staging"; mkdir -p "$ST6"
DS_MODE=ask sh "$ENGINE" delta "$MF6" "$B6" | while IFS= read -r rel; do [ -n "$rel" ] || continue; mkdir -p "$ST6/$(dirname "$rel")"; cp "$A6/$rel" "$ST6/$rel"; done
TAKE6="$WORK/s6.take"; : > "$TAKE6"
BK6="$WORK/s6/bk"; DS_MODE=ask DS_TAKE="$TAKE6" sh "$ENGINE" apply-net "$MF6" "$ST6" "$B6" "$BK6"
check "cat: save conflict kept mine"    "$(cat "$B6/Saves/GBC/Mario Golf.sav")"                 "B-CHAR"
check "cat: state conflict kept mine"   "$(cat "$B6/.userdata/shared/GB-gambatte/Mario.st0")"   "B-STATE"
check "cat: config took the sender"     "$(cat "$B6/.userdata/tg5040/GB-gambatte/Mario.cfg")"   "A-CFG"
check "cat: recents untouched (per device)" "$(cat "$B6/.userdata/shared/.minui/recent.txt")"    "B-RECENT"
check "cat: replaced config backed up"  "$(cat "$BK6/.userdata/tg5040/GB-gambatte/Mario.cfg")"  "B-CFG"

# build_export: nested paths are symlinked; our own backups / card root are NEVER exposed
CARD6="$WORK/s6card"; SV6="$WORK/s6serve"
mk "$CARD6" "Saves/GBC/x.sav" "S"
mk "$CARD6" ".userdata/shared/GB-gambatte/x.st0" "ST"
mk "$CARD6" ".userdata/shared/.minui/recent.txt" "R"
mk "$CARD6" ".userdata/shared/.minui/favorites.txt" "F"
mk "$CARD6" ".userdata/tg5040/devicesync/backups/old/junk" "OUR-BACKUP"   # must NEVER leave the device
mk "$CARD6" "wifi.txt" "SSID+PSK"                                          # must NEVER be exported
sh "$NET" build-export "$CARD6" "$SV6" "Saves" ".userdata/shared/GB-gambatte" ".userdata/shared/.minui/recent.txt" ".userdata/shared/.minui/favorites.txt" >/dev/null 2>&1
check "export: nested state symlinked"     "$([ -e "$SV6/.userdata/shared/GB-gambatte/x.st0" ] && echo yes || echo no)"   "yes"
check "export: recent.txt symlinked"       "$([ -e "$SV6/.userdata/shared/.minui/recent.txt" ] && echo yes || echo no)"  "yes"
check "export: our backups NOT reachable"  "$([ -e "$SV6/.userdata/tg5040/devicesync/backups/old/junk" ] && echo LEAK || echo safe)" "safe"
check "export: wifi.txt NOT reachable"     "$([ -e "$SV6/wifi.txt" ] && echo LEAK || echo safe)" "safe"
MANI6=$(cat "$SV6/_dsync_manifest" 2>/dev/null)
has   ".userdata/shared/GB-gambatte/x.st0" "$MANI6"
nohas "devicesync" "$MANI6"
nohas "wifi.txt" "$MANI6"
# recent.txt is exported as a symlink to a FILE (not a dir): the manifest must describe the target, never
# the link. On 2026-09-05 ls -ln (no -L) emitted "recent.txt -> /card/..." with the link's own size, so
# the receiver requested a URL that did not exist and that one file failed every time.
nohas " -> " "$MANI6"
nohas "recent.txt" "$MANI6"   # exported by an explicit list, but classified other: never in a manifest
RLINE=$(printf '%s\n' "$MANI6" | grep "^.userdata/shared/.minui/favorites.txt${TAB}")
check "symlinked file: exact rel present"       "$(printf '%s\n' "$RLINE" | grep -c .)" "1"
check "symlinked file: size is the target's (1)" "$(printf '%s\n' "$RLINE" | cut -f2)" "1"
check "symlinked file: hash column is '-' (hashless)" "$(printf '%s\n' "$RLINE" | cut -f5)" "-"

######################################################################
echo "########## SCENARIO 7: v2 -- one authoritative plan, crash-safe apply, backup-first restore ##########"
# v2 computes the merge ONCE (on the host) and hands BOTH devices the same plan file:
#   ACTION \t CLASS \t SIZE \t REL [\t HASH \t MTIME]   -- "take" = copy staging -> dst.
md5of() { if command -v md5sum >/dev/null 2>&1; then md5sum "$1" | cut -d' ' -f1; else md5 -q "$1"; fi; }
szof()  { wc -c < "$1" | tr -d ' '; }
planln(){ printf 'take\t%s\t%s\t%s\t%s\t%s\n' "$2" "$(szof "$1/$3")" "$3" "$(md5of "$1/$3")" "${4:-0}"; }

S7="$WORK/s7"; L7="$S7/local"; ST7="$S7/staging"; BK7="$S7/backups/20260918-1000"; mkdir -p "$L7" "$ST7"
mk "$L7"  "Saves/GBA/keep.srm"      "LOCAL-PRE-SYNC"        # the plan overwrites it -> must be backed up
mk "$L7"  "Saves/GBA/untouched.srm" "NEVER-IN-THE-PLAN"     # not in the plan -> must never be touched
mk "$ST7" "Saves/GBA/keep.srm"      "PEER-VERSION"
mk "$ST7" "Saves/GBA/fresh.srm"     "PEER-NEW-SAVE"
mk "$ST7" "Roms/GBA/Metroid Fusion (USA).gba" "PEER-ROM"    # spaces + parens through the whole pipeline
ROM7="Roms/GBA/Metroid Fusion (USA).gba"
PLAN7="$S7/plan"
{ planln "$ST7" save "Saves/GBA/keep.srm"  1700000000
  planln "$ST7" save "Saves/GBA/fresh.srm" 1700000000
  printf 'take\trom\t%s\t%s\t-\t0\n' "$(szof "$ST7/$ROM7")" "$ROM7"   # ROM hash is "-": size-only, by design
} > "$PLAN7"

echo "== 7a: resume-check lists only what is missing or short in staging =="
check "7a: fully staged -> nothing to fetch" "$(E resume-check "$PLAN7" "$ST7" | grep -c .)" "0"
rm -f "$ST7/Saves/GBA/fresh.srm"                   # never downloaded
printf 'SHORT' > "$ST7/$ROM7"                      # partial download (size mismatch)
printf 'PEER-VERSIOM' > "$ST7/Saves/GBA/keep.srm"  # SAME SIZE, wrong bytes -> only the hash catches this
RC7=$(E resume-check "$PLAN7" "$ST7")
has "Saves/GBA/fresh.srm" "$RC7"
has "$ROM7" "$RC7"
has "Saves/GBA/keep.srm" "$RC7"
check "7a: exactly the 3 unstaged, nothing else" "$(printf '%s\n' "$RC7" | grep -c .)" "3"
mk "$ST7" "Saves/GBA/keep.srm"  "PEER-VERSION"     # re-pull them
mk "$ST7" "Saves/GBA/fresh.srm" "PEER-NEW-SAVE"
mk "$ST7" "$ROM7" "PEER-ROM"
check "7a: after the re-pull -> nothing left to fetch" "$(E resume-check "$PLAN7" "$ST7" | grep -c .)" "0"

echo "== 7b: apply-plan backs up what it overwrites, writes atomically, journals COMPLETE =="
E apply-plan "$PLAN7" "$ST7" "$L7" "$BK7"
check "7b: overwritten with the peer's bytes"        "$(cat "$L7/Saves/GBA/keep.srm")"      "PEER-VERSION"
check "7b: the pre-sync file is BACKED UP"           "$(cat "$BK7/Saves/GBA/keep.srm")"     "LOCAL-PRE-SYNC"
check "7b: new save added"                           "$(cat "$L7/Saves/GBA/fresh.srm")"     "PEER-NEW-SAVE"
check "7b: spaces+parens name survived"              "$(cat "$L7/$ROM7")"                   "PEER-ROM"
check "7b: a file not in the plan is untouched"      "$(cat "$L7/Saves/GBA/untouched.srm")" "NEVER-IN-THE-PLAN"
check "7b: the plan's mtime is stamped on the file"  "$(mt "$L7/Saves/GBA/keep.srm")"       "1700000000"
if ls "$L7"/Saves/GBA/*.dsync.tmp >/dev/null 2>&1; then bad "7b: temp file left behind"; else ok "7b: no temp files left"; fi
check "7b: journal says COMPLETE"                    "$(E journal-status "$BK7")"           "COMPLETE"
E apply-plan "$PLAN7" "$ST7" "$L7" "$BK7" >/dev/null 2>&1; RC7B=$?
check "7b: a reused backup dir is refused" "$([ "$RC7B" != 0 ] && echo refused || echo allowed)" "refused"

echo "== 7c: restore is backup-first -- neither of the two undo data-loss bugs can exist =="
printf 'PLAYED-AFTER!' > "$L7/Saves/GBA/fresh.srm"          # bug 1: a played save, SAME SIZE as the synced one
check "7c: the played save is the same size as the synced one (the bug's shape)" \
      "$(szof "$L7/Saves/GBA/fresh.srm")" "$(szof "$ST7/Saves/GBA/fresh.srm")"
printf 'PLAYED-AFTER-THE-SYNC' > "$L7/Saves/GBA/keep.srm"   # bug 2: progress made after the sync
SNAP7=$(E restore "$L7" "$BK7")
check "7c: restore put the pre-sync file back"   "$(cat "$L7/Saves/GBA/keep.srm")"   "LOCAL-PRE-SYNC"
check "7c: restore removed the added file"       "$([ -e "$L7/Saves/GBA/fresh.srm" ] && echo present || echo removed)" "removed"
check "7c: BUG1 -- the same-size played save is kept in the new snapshot" "$(cat "$SNAP7/Saves/GBA/fresh.srm")" "PLAYED-AFTER!"
check "7c: BUG2 -- post-sync progress is kept in the new snapshot"        "$(cat "$SNAP7/Saves/GBA/keep.srm")"  "PLAYED-AFTER-THE-SYNC"
check "7c: the untouched file is still untouched" "$(cat "$L7/Saves/GBA/untouched.srm")" "NEVER-IN-THE-PLAN"
check "7c: the original backup is NOT clobbered by the restore" "$(cat "$BK7/Saves/GBA/keep.srm")" "LOCAL-PRE-SYNC"
E restore "$L7" "$SNAP7" >/dev/null
check "7c: restoring the snapshot brings the played save back" "$(cat "$L7/Saves/GBA/fresh.srm")" "PLAYED-AFTER!"
check "7c: restoring the snapshot brings the progress back"    "$(cat "$L7/Saves/GBA/keep.srm")"  "PLAYED-AFTER-THE-SYNC"

echo "== 7d: an interrupted apply is detectable (journal-status) and finishable (resume-apply) =="
S8="$WORK/s8"; L8="$S8/local"; ST8="$S8/staging"; BK8="$S8/backups/20260918-1100"; mkdir -p "$L8" "$ST8"
mk "$L8"  "Saves/GBA/a.srm" "A-PRE-SYNC"
mk "$ST8" "Saves/GBA/a.srm" "A-FROM-PEER"
mk "$ST8" "Saves/GBA/b.srm" "B-FROM-PEER"
PLAN8="$S8/plan"
{ planln "$ST8" save "Saves/GBA/a.srm" 1700000000; planln "$ST8" save "Saves/GBA/b.srm" 1700000000; } > "$PLAN8"
rm -f "$ST8/Saves/GBA/b.srm"                       # b never finished downloading: the apply stops on it
E apply-plan "$PLAN8" "$ST8" "$L8" "$BK8" 2>/dev/null
check "7d: journal-status names the file it stopped on" "$(E journal-status "$BK8")"    "INCOMPLETE${TAB}Saves/GBA/b.srm"
check "7d: the finished file did land"                  "$(cat "$L8/Saves/GBA/a.srm")"  "A-FROM-PEER"
check "7d: its pre-sync copy is in the backup"          "$(cat "$BK8/Saves/GBA/a.srm")" "A-PRE-SYNC"
mk "$ST8" "Saves/GBA/b.srm" "B-FROM-PEER"          # re-pulled, then finish the same transaction
E resume-apply "$PLAN8" "$ST8" "$L8" "$BK8"
check "7d: resume-apply finished the plan"              "$(E journal-status "$BK8")"    "COMPLETE"
check "7d: the remaining file landed"                   "$(cat "$L8/Saves/GBA/b.srm")"  "B-FROM-PEER"
check "7d: resume did NOT re-back-up the synced bytes"  "$(cat "$BK8/Saves/GBA/a.srm")" "A-PRE-SYNC"
# a power cut leaves a BEGIN with no DONE: seen as INCOMPLETE, and re-applying a file is harmless
printf 'BEGIN\tSaves/GBA/a.srm\n' >> "$BK8/journal.log"
check "7d: a stray BEGIN reads as INCOMPLETE" "$(E journal-status "$BK8")" "INCOMPLETE${TAB}Saves/GBA/a.srm"
E resume-apply "$PLAN8" "$ST8" "$L8" "$BK8"
check "7d: resume-apply closes it out"           "$(E journal-status "$BK8")"    "COMPLETE"
check "7d: applying twice changed nothing"       "$(cat "$L8/Saves/GBA/a.srm")"  "A-FROM-PEER"
check "7d: the pre-sync backup still survives"   "$(cat "$BK8/Saves/GBA/a.srm")" "A-PRE-SYNC"
E restore "$L8" "$BK8" >/dev/null                  # a resumed sync still restores cleanly
check "7d: restore after a resumed sync brings the original back" "$(cat "$L8/Saves/GBA/a.srm")" "A-PRE-SYNC"
check "7d: restore removed the file the sync added" "$([ -e "$L8/Saves/GBA/b.srm" ] && echo present || echo removed)" "removed"

echo "== 7e: a backup that cannot be written must NOT overwrite the local save (and stays retryable) =="
S9="$WORK/s9"; L9="$S9/local"; ST9="$S9/staging"; BK9="$S9/backups/20260918-1200"; mkdir -p "$L9" "$ST9" "$BK9"
mk "$L9"  "Saves/GBA/c.srm" "C-LOCAL"
mk "$ST9" "Saves/GBA/c.srm" "C-FROM-PEER"
PLAN9="$S9/plan"; planln "$ST9" save "Saves/GBA/c.srm" 1700000000 > "$PLAN9"
printf 'not-a-dir' > "$BK9/Saves"                  # the backup path cannot be created -> the backup fails
E apply-plan "$PLAN9" "$ST9" "$L9" "$BK9" >/dev/null 2>&1
check "7e: backup-fail leaves the local save intact" "$(cat "$L9/Saves/GBA/c.srm")" "C-LOCAL"
check "7e: and the plan reads INCOMPLETE"            "$(E journal-status "$BK9")"    "INCOMPLETE${TAB}Saves/GBA/c.srm"
rm -f "$BK9/Saves"                                 # fault cleared: the retry must now be able to finish
E resume-apply "$PLAN9" "$ST9" "$L9" "$BK9"
check "7e: resume after the fault clears applies it" "$(cat "$L9/Saves/GBA/c.srm")"  "C-FROM-PEER"
check "7e: with the pre-sync copy backed up"         "$(cat "$BK9/Saves/GBA/c.srm")" "C-LOCAL"

echo "== 7f: a rel listed twice in one plan is applied once (never backs up its own new bytes) =="
S10="$WORK/s10"; L10="$S10/local"; ST10="$S10/staging"; BK10="$S10/backups/20260918-1300"; mkdir -p "$L10" "$ST10"
mk "$ST10" "Saves/GBA/d.srm" "D-FROM-PEER"
PLAN10="$S10/plan"
{ planln "$ST10" save "Saves/GBA/d.srm" 1700000000; planln "$ST10" save "Saves/GBA/d.srm" 1700000000; } > "$PLAN10"
E apply-plan "$PLAN10" "$ST10" "$L10" "$BK10"
check "7f: exactly one ops.log entry"                     "$(grep -c . "$BK10/ops.log")" "1"
check "7f: recorded as an ADD, not an UPDATE of itself"   "$(cut -f1 "$BK10/ops.log")"   "ADD"
E restore "$L10" "$BK10" >/dev/null
check "7f: so restore still removes the added file" "$([ -e "$L10/Saves/GBA/d.srm" ] && echo present || echo removed)" "removed"

######################################################################
echo "########## SCENARIO 8: the backup must be VERIFIED before anything is overwritten ##########"
# The review's data-loss finding: order per file is BEGIN -> cp dst->bdir -> journal BACKUP -> write dst.
# A power cut DURING the cp left a SHORT file at bdir/<rel> with no BACKUP line, and resume-apply took
# "a file is there" as "the original is safe" and wrote the peer's bytes over the real save. The pre-sync
# save then existed nowhere: restore put back the truncated stub.
ORIG8="REAL-LOCAL-SAVE-WITH-100-HOURS-OF-PROGRESS"
setup_torn() { # <root> <backup dir contents|""> : a run interrupted after BEGIN, before the write
	TR="$1"; TL="$TR/local"; TST="$TR/staging"; TBK="$TR/backups/20260918-1400"; mkdir -p "$TL" "$TST" "$TBK"
	mk "$TL"  "Saves/GBA/z.srm" "$ORIG8"
	mk "$TST" "Saves/GBA/z.srm" "PEER-SAVE"
	planln "$TST" save "Saves/GBA/z.srm" 1700000000 > "$TR/plan"
	printf 'BEGIN\tSaves/GBA/z.srm\n' > "$TBK/journal.log"; : > "$TBK/ops.log"
	if [ -n "$2" ]; then mkdir -p "$TBK/Saves/GBA"; printf '%s' "$2" > "$TBK/Saves/GBA/z.srm"; fi
}

echo "== 8a: a TRUNCATED backup with no journal line never stands in for the original =="
setup_torn "$WORK/s8a" "REAL-LOCAL-SAVE-WI"        # the interrupted cp: 18 of 42 bytes
E resume-apply "$WORK/s8a/plan" "$WORK/s8a/staging" "$WORK/s8a/local" "$WORK/s8a/backups/20260918-1400" >/dev/null 2>&1
check "8a: the pre-sync save survives VERBATIM in the backup" \
      "$(cat "$WORK/s8a/backups/20260918-1400/Saves/GBA/z.srm")" "$ORIG8"
check "8a: the backup is the full length, not the 18-byte stub" \
      "$(szof "$WORK/s8a/backups/20260918-1400/Saves/GBA/z.srm")" "$(printf '%s' "$ORIG8" | wc -c | tr -d ' ')"
E restore "$WORK/s8a/local" "$WORK/s8a/backups/20260918-1400" >/dev/null 2>&1
check "8a: so restore puts the REAL save back (not the stub)" \
      "$(cat "$WORK/s8a/local/Saves/GBA/z.srm")" "$ORIG8"

echo "== 8b: an unverifiable backup + an already-written file: the original is kept, never re-copied =="
# the journal lost its BACKUP line but the write DID land (dst matches the plan). The backup dir holds
# the real original at a different size -- re-copying dst over it would put the SYNCED bytes in the
# backup and lose the original for good.
setup_torn "$WORK/s8b" "$ORIG8"
printf 'PEER-SAVE' > "$WORK/s8b/local/Saves/GBA/z.srm"     # the write already landed
E resume-apply "$WORK/s8b/plan" "$WORK/s8b/staging" "$WORK/s8b/local" "$WORK/s8b/backups/20260918-1400" >/dev/null 2>&1
check "8b: the original in the backup was NOT overwritten" \
      "$(cat "$WORK/s8b/backups/20260918-1400/Saves/GBA/z.srm")" "$ORIG8"
check "8b: and the plan still finishes"  "$(E journal-status "$WORK/s8b/backups/20260918-1400")" "COMPLETE"

echo "== 8c: a journalled backup that goes missing/short refuses the write (stays retryable) =="
S8C="$WORK/s8c"; L8C="$S8C/local"; ST8C="$S8C/staging"; BK8C="$S8C/backups/20260918-1500"; mkdir -p "$L8C" "$ST8C"
mk "$L8C"  "Saves/GBA/w.srm" "W-LOCAL-ORIGINAL"
mk "$ST8C" "Saves/GBA/w.srm" "W-FROM-PEER"
mk "$ST8C" "Saves/GBA/w2.srm" "W2-FROM-PEER"
PLAN8C="$S8C/plan"
{ planln "$ST8C" save "Saves/GBA/w.srm" 1700000000; planln "$ST8C" save "Saves/GBA/w2.srm" 1700000000; } > "$PLAN8C"
rm -f "$ST8C/Saves/GBA/w2.srm"                     # w2 never downloaded -> the run stops INCOMPLETE after w
E apply-plan "$PLAN8C" "$ST8C" "$L8C" "$BK8C" >/dev/null 2>&1
check "8c: w landed and its original is journalled as backed up" "$(cat "$BK8C/Saves/GBA/w.srm")" "W-LOCAL-ORIGINAL"
BKSZ8C=$(awk -F"$TAB" '$1=="BACKUP"{print $3}' "$BK8C/journal.log" | head -1)
check "8c: the journal records the backup's verified size" "$BKSZ8C" "$(wc -c < "$BK8C/Saves/GBA/w.srm" | tr -d ' ')"
# now corrupt the backup and re-run the same file: the write must be refused, not repeated
printf 'TRUNC' > "$BK8C/Saves/GBA/w.srm"
printf 'PLAYED-SINCE' > "$L8C/Saves/GBA/w.srm"
sed '/^DONE/d' "$BK8C/journal.log" > "$BK8C/journal.log.x" && mv "$BK8C/journal.log.x" "$BK8C/journal.log"
mk "$ST8C" "Saves/GBA/w2.srm" "W2-FROM-PEER"
E resume-apply "$PLAN8C" "$ST8C" "$L8C" "$BK8C" >/dev/null 2>&1; RC8C=$?
check "8c: the live file was NOT overwritten behind the damaged backup" "$(cat "$L8C/Saves/GBA/w.srm")" "PLAYED-SINCE"
check "8c: and it reports failure"        "$([ "$RC8C" != 0 ] && echo refused || echo silent)" "refused"
check "8c: the rest of the plan still applied" "$(cat "$L8C/Saves/GBA/w2.srm")" "W2-FROM-PEER"
case "$(E journal-status "$BK8C")" in INCOMPLETE*) ok "8c: the journal stays INCOMPLETE (retryable)" ;; *) bad "8c: journal claims COMPLETE after a refused file" ;; esac

echo "== 8e: RESUME re-verifies the LIVE file -- an ADD the user created meanwhile is never clobbered =="
# The reviewer's reproduction: the plan ADDs a save that does not exist locally, the apply journals
# "BACKUP none", and the battery dies before the write. The user then plays that game for the FIRST time
# for 20 hours, which CREATES the file, and only later picks "Resume interrupted sync". Resume used to
# reason entirely about the state at the interruption: it wrote the staged bytes over those 20 hours with
# NO copy anywhere, and logged it as an ADD so a later restore DELETED the file outright.
S8E="$WORK/s8e"; L8E="$S8E/local"; ST8E="$S8E/staging"; BK8E="$S8E/backups/20260918-1800"; mkdir -p "$L8E" "$ST8E" "$BK8E"
mk "$ST8E" "Saves/GBA/x.srm" "PEER-SAVE-FROM-THE-INTERRUPTED-SYNC"
PLAN8E="$S8E/plan"; planln "$ST8E" save "Saves/GBA/x.srm" 1700000000 > "$PLAN8E"
printf 'BEGIN\tSaves/GBA/x.srm\nBACKUP\tnone\t0\tSaves/GBA/x.srm\n' > "$BK8E/journal.log"; : > "$BK8E/ops.log"
mk "$L8E" "Saves/GBA/x.srm" "TWENTY-HOURS-OF-PROGRESS"     # created AFTER the interruption
E resume-apply "$PLAN8E" "$ST8E" "$L8E" "$BK8E" >/dev/null 2>&1
check "8e: the save created after the interruption is KEPT (stale write skipped)" "$(cat "$L8E/Saves/GBA/x.srm")" "TWENTY-HOURS-OF-PROGRESS"
check "8e: no ops.log line, so restore cannot touch it" "$(awk -F"$TAB" '$3=="Saves/GBA/x.srm"{print $1}' "$BK8E/ops.log")" ""
check "8e: transaction completes" "$(E journal-status "$BK8E")" "COMPLETE"
check "8e: journal COMPLETE"                      "$(E journal-status "$BK8E")" "COMPLETE"
E restore "$L8E" "$BK8E" >/dev/null 2>&1
check "8e: so restore puts the 20 hours BACK instead of deleting the file" \
      "$(cat "$L8E/Saves/GBA/x.srm" 2>/dev/null)" "TWENTY-HOURS-OF-PROGRESS"

echo "== 8f: RESUME re-verifies the LIVE file -- an edit made after the interruption is copied first =="
# Same shape, but a backup DOES exist: it was taken BEFORE the interruption, so it is stale the moment the
# user edits the live file afterwards. Both states must survive the resumed write.
S8F="$WORK/s8f"; L8F="$S8F/local"; ST8F="$S8F/staging"; BK8F="$S8F/backups/20260918-1900"; mkdir -p "$L8F" "$ST8F" "$BK8F"
mk "$L8F"  "Saves/GBA/y.srm" "PRE-SYNC-ORIGINAL"
mk "$ST8F" "Saves/GBA/y.srm" "PEER-SAVE"
PLAN8F="$S8F/plan"; planln "$ST8F" save "Saves/GBA/y.srm" 1700000000 > "$PLAN8F"
mkdir -p "$BK8F/Saves/GBA"; printf 'PRE-SYNC-ORIGINAL' > "$BK8F/Saves/GBA/y.srm"
printf 'BEGIN\tSaves/GBA/y.srm\nBACKUP\thave\t%s\tSaves/GBA/y.srm\n' "$(szof "$BK8F/Saves/GBA/y.srm")" > "$BK8F/journal.log"
: > "$BK8F/ops.log"
printf 'PLAYED-AFTER-THE-INTERRUPTION' > "$L8F/Saves/GBA/y.srm"   # the live file moved on
E resume-apply "$PLAN8F" "$ST8F" "$L8F" "$BK8F" >/dev/null 2>&1
# the live edit is the newest state: it is KEPT, the stale staged write is skipped, the transaction completes
check "8f: the post-interruption edit stays live (staged write skipped)" "$(cat "$L8F/Saves/GBA/y.srm")" "PLAYED-AFTER-THE-INTERRUPTION"
check "8f: the pre-sync original is STILL the restore copy" "$(cat "$BK8F/Saves/GBA/y.srm")" "PRE-SYNC-ORIGINAL"
check "8f: journal completes with a DONE keep line"         "$(E journal-status "$BK8F")/$(grep -c "^DONE.keep" "$BK8F/journal.log")" "COMPLETE/1"
E restore "$L8F" "$BK8F" >/dev/null 2>&1
check "8f: restore leaves the kept edit alone (no ops.log entry)" "$(cat "$L8F/Saves/GBA/y.srm")" "PLAYED-AFTER-THE-INTERRUPTION"

echo "== 8h: HASHLESS resume -- a fixed-size save edited after the cut is copied first, not clobbered =="
# Saves are hashless now (identity = size + mtime). The reviewer's finding: a fixed-size SRAM save the
# user edits after the interruption is the SAME SIZE as the staged peer copy, so a size-ONLY resume check
# wrongly reads "already applied" and overwrites the new progress with no copy. The mtime must catch it.
# This plan carries hash "-" (a real production plan), unlike 8e/8f which used real hashes.
S8H="$WORK/s8h"; L8H="$S8H/local"; ST8H="$S8H/staging"; BK8H="$S8H/backups/20260918-2100"; mkdir -p "$L8H" "$ST8H" "$BK8H"
mk "$ST8H" "Saves/GBA/z.srm" "PEER-SAVE"                              # 9 bytes, from the interrupted sync
PLAN8H="$S8H/plan"; printf 'take\tsave\t%s\tSaves/GBA/z.srm\t-\t1700000000\n' "$(szof "$ST8H/Saves/GBA/z.srm")" > "$PLAN8H"
printf 'BEGIN\tSaves/GBA/z.srm\nBACKUP\tnone\t0\tSaves/GBA/z.srm\n' > "$BK8H/journal.log"; : > "$BK8H/ops.log"
mk "$L8H" "Saves/GBA/z.srm" "USER-EDIT" 202601010000                 # SAME 9 bytes, different content + mtime
E resume-apply "$PLAN8H" "$ST8H" "$L8H" "$BK8H" >/dev/null 2>&1
check "8h: the same-size user edit is KEPT (stale write skipped)" "$(cat "$L8H/Saves/GBA/z.srm")" "USER-EDIT"
check "8h: no ops.log line for it"                        "$(awk -F"$TAB" '$3=="Saves/GBA/z.srm"{print $1}' "$BK8H/ops.log")" ""
check "8h: transaction completes"                         "$(E journal-status "$BK8H")" "COMPLETE"
E restore "$L8H" "$BK8H" >/dev/null 2>&1
check "8h: restore puts the user edit back, not deletes it" "$(cat "$L8H/Saves/GBA/z.srm" 2>/dev/null)" "USER-EDIT"

echo "== 8g: an unreadable plan is an ERROR -- it must never stamp COMPLETE on an interrupted sync =="
# With no readable plan the work list is empty; the old code returned 0 and appended COMPLETE, so the
# caller deleted the resume pointer + staging and the half-applied transaction could never be finished.
S8G="$WORK/s8g"; L8G="$S8G/local"; ST8G="$S8G/staging"; BK8G="$S8G/backups/20260918-2000"; mkdir -p "$L8G" "$ST8G" "$BK8G"
mk "$L8G"  "Saves/GBA/q.srm" "Q-LOCAL"
mk "$ST8G" "Saves/GBA/q.srm" "Q-FROM-PEER"
printf 'BEGIN\tSaves/GBA/q.srm\n' > "$BK8G/journal.log"; : > "$BK8G/ops.log"
for bad in no-such-plan empty-plan junk-plan; do
	case "$bad" in empty-plan) : > "$S8G/$bad" ;; junk-plan) printf 'garbage, not a plan at all\n' > "$S8G/$bad" ;; esac
	E resume-apply "$S8G/$bad" "$ST8G" "$L8G" "$BK8G" >/dev/null 2>&1; RC8G=$?
	check "8g: $bad returns non-zero"     "$([ "$RC8G" != 0 ] && echo error || echo silent)" "error"
	check "8g: $bad did not write COMPLETE" "$(grep -c '^COMPLETE' "$BK8G/journal.log")" "0"
done
case "$(E journal-status "$BK8G")" in INCOMPLETE*) ok "8g: the transaction stays resumable" ;; *) bad "8g: journal claims COMPLETE after an unreadable plan" ;; esac
PLAN8G="$S8G/plan"; planln "$ST8G" save "Saves/GBA/q.srm" 1700000000 > "$PLAN8G"
E resume-apply "$PLAN8G" "$ST8G" "$L8G" "$BK8G" >/dev/null 2>&1
check "8g: the real plan still finishes it" "$(E journal-status "$BK8G")" "COMPLETE"
check "8g: with the local original backed up" "$(cat "$BK8G/Saves/GBA/q.srm")" "Q-LOCAL"
# apply-plan (new) fails closed on a bad plan too, and leaves no half-made snapshot claiming COMPLETE
BK8GN="$S8G/backups/20260918-2100"
E apply-plan "$S8G/no-such-plan" "$ST8G" "$L8G" "$BK8GN" >/dev/null 2>&1; RC8GN=$?
check "8g: apply-plan with a missing plan returns non-zero" "$([ "$RC8GN" != 0 ] && echo error || echo silent)" "error"
check "8g: and no COMPLETE journal was created" "$([ -e "$BK8GN/journal.log" ] && echo made || echo none)" "none"

echo "== 8d: a backup copy is written .part-then-mv, so a torn one is never at <bdir>/<rel> =="
S8D="$WORK/s8d"; L8D="$S8D/local"; ST8D="$S8D/staging"; BK8D="$S8D/backups/20260918-1600"; mkdir -p "$L8D" "$ST8D"
mk "$L8D"  "Saves/GBA/p.srm" "P-ORIGINAL"
mk "$ST8D" "Saves/GBA/p.srm" "P-FROM-PEER"
PLAN8D="$S8D/plan"; planln "$ST8D" save "Saves/GBA/p.srm" 1700000000 > "$PLAN8D"
E apply-plan "$PLAN8D" "$ST8D" "$L8D" "$BK8D" >/dev/null 2>&1
if find "$BK8D" -name '*.dsync.part' | grep -q .; then bad "8d: a .part was left in the backup dir"; else ok "8d: no .part left in the backup dir"; fi
check "8d: the backup is the whole original" "$(cat "$BK8D/Saves/GBA/p.srm")" "P-ORIGINAL"

######################################################################
echo "########## SCENARIO 9: stranded .dsync.tmp is scratch, never a save ##########"
# A power cut between the tmp write and the atomic mv leaves <save>.dsync.tmp on the card. It used to
# classify as a save, so the next sync manifested it, showed it in the delta and copied the fragment
# to the other device.
S9T="$WORK/s9t"; C9="$S9T/card"; D9="$S9T/dst"; mkdir -p "$C9" "$D9"
mk "$C9" "Saves/GBC/Zelda.sav" "REAL-SAVE"
mk "$C9" "Saves/GBC/Zelda.sav.dsync.tmp" "HALF-WRITTEN-FRAGMENT"     # the orphan
mk "$C9" "Roms/1) Game Boy Color (GBC)/Zelda.gbc" "ROM"
MF9="$S9T/mf"; E manifest "$C9" > "$MF9"
nohas "dsync.tmp" "$(cat "$MF9")"
has   "Saves/GBC/Zelda.sav" "$(cat "$MF9")"
P9=$(E plan-rich "$MF9" "$D9")
nohas "dsync.tmp" "$P9"
D9L=$(E delta "$MF9" "$D9")
nohas "dsync.tmp" "$D9L"
MRG9=$(E merge "$MF9" "$MF9")
nohas "dsync.tmp" "$MRG9"
GF9=$(E game-files "$C9" "Roms/1) Game Boy Color (GBC)/Zelda.gbc" 1 1)
nohas "dsync.tmp" "$GF9"
# and an apply sweeps the card clean of them
S9B="$S9T/bk/20260918-1700"; ST9B="$S9T/staging"; mkdir -p "$ST9B"
mk "$ST9B" "Saves/GBC/New.sav" "NEW"
PLAN9="$S9T/plan"; planln "$ST9B" save "Saves/GBC/New.sav" 1700000000 > "$PLAN9"
E apply-plan "$PLAN9" "$ST9B" "$C9" "$S9B" >/dev/null 2>&1
check "9: apply swept the stranded tmp off the card" \
      "$([ -e "$C9/Saves/GBC/Zelda.sav.dsync.tmp" ] && echo present || echo swept)" "swept"
check "9: the real save beside it is untouched" "$(cat "$C9/Saves/GBC/Zelda.sav")" "REAL-SAVE"
# the sweep is PLAN-SCOPED (only dirs this plan writes): scratch elsewhere is left for the sync that
# next touches that dir, instead of walking the whole card on every apply
mk "$C9" "Saves/PS/Other.srm.dsync.tmp" "STRAY"
S9C="$S9T/bk/20260918-1701"; PLAN9C="$S9T/plan2"; planln "$ST9B" save "Saves/GBC/New.sav" 1700000001 > "$PLAN9C"
E apply-plan "$PLAN9C" "$ST9B" "$C9" "$S9C" >/dev/null 2>&1
check "9: sweep is plan-scoped (unplanned dir left alone)" "$([ -e "$C9/Saves/PS/Other.srm.dsync.tmp" ] && echo present || echo swept)" "present"

######################################################################
echo "########## SCENARIO 10: plan-need budgets BOTH copies (staging + applied + backups) ##########"
# Every planned byte lands twice before staging is cleared, so the old "plan bytes + 10%" check offered
# Sync for transfers that could not fit and filled the card mid-apply.
S10N="$WORK/s10n"; L10N="$S10N/local"; ST10N="$S10N/staging"; mkdir -p "$L10N" "$ST10N"
BIG=$(awk 'BEGIN{ s=""; for(i=0;i<2048;i++) s=s "0123456789012345678901234567890123456789012345678901234567890123"; print s }')
printf '%s' "$BIG" > "$ST10N/big.bin"                      # 128 KB staged
mkdir -p "$L10N"; printf '%s' "$BIG" > "$L10N/big.bin"     # the file it replaces: another 128 KB in the backup
PLAN10N="$S10N/plan"; printf 'take\tother\t%s\tbig.bin\t-\t0\n' "$(szof "$ST10N/big.bin")" > "$PLAN10N"
NEED_NO_DST=$(E plan-need "$PLAN10N")
NEED_DST=$(E plan-need "$PLAN10N" "$L10N")
check "10: without dst = staged + applied (2 x 128 KB)"        "$NEED_NO_DST" "256"
check "10: with dst    = staged + applied + the backup copy"   "$NEED_DST"    "384"
printf 'skip\tother\t10\tx\n' > "$S10N/p0"
check "10: a plan with nothing to copy needs nothing"          "$(E plan-need "$S10N/p0" "$L10N")" "0"

######################################################################
echo "########## prune ##########"
PR="$WORK/backups"; mkdir -p "$PR"
for d in 20260101-0000 20260102-0000 20260103-0000 20260104-0000 20260105-0000 20260106-0000 20260107-0000; do mkdir -p "$PR/$d"; done
E prune "$PR" 5
check "prune leaves 5" "$(ls -1 "$PR" | wc -l | tr -d ' ')" "5"
if [ -d "$PR/20260107-0000" ] && [ ! -d "$PR/20260101-0000" ]; then ok "prune kept newest, dropped oldest"; else bad "prune kept the wrong set"; fi

######################################################################
# ---- pick tree: systems / games / game_files (the Send screens are built from these) ----
C="$WORK/pick"; mkdir -p "$C"
mk "$C" "Roms/1) Game Boy Color (GBC)/Zelda DX - Links Awakening.gbc" "ROM1"
mk "$C" "Roms/1) Game Boy Color (GBC)/Dr. Mario.gbc" "ROM2"
mk "$C" "Roms/1) Game Boy Color (GBC)/.hidden.gbc" "HIDDEN"
mk "$C" "Roms/6) PlayStation (PS)/Final Fantasy VII/disc1.bin" "D1"
mk "$C" "Roms/6) PlayStation (PS)/Final Fantasy VII/FF7.m3u" "M3U"
mkdir -p "$C/Roms/2) Game Boy Advance (GBA)"
mk "$C" "Saves/GBC/Zelda DX - Links Awakening.gbc.sav" "SAVE" 202609010000
mk "$C" ".userdata/shared/GBC-gambatte/Zelda DX - Links Awakening.st0" "STATE"
mk "$C" ".userdata/shared/GBC-gambatte/Zelda DX - Links Awakening.st0.png" "THUMB"
mk "$C" "Saves/PS/Final Fantasy VII.m3u.sav" "PSSAVE"
SYS=$(E systems "$C")
check "systems: two consoles with games (empty GBA omitted)" "$(printf '%s\n' "$SYS" | wc -l | tr -d ' ')" "2"
check "systems: GBC row" "$(printf '%s\n' "$SYS" | grep GBC | cut -f2,3,4)" "Game Boy Color${TAB}GBC${TAB}2"
check "systems: PS dir game counts once" "$(printf '%s\n' "$SYS" | grep PS | cut -f4)" "1"
G=$(E games "$C" "Roms/1) Game Boy Color (GBC)")
check "games: hidden file skipped" "$(printf '%s\n' "$G" | wc -l | tr -d ' ')" "2"
check "games: zelda has save + 1 state" "$(printf '%s\n' "$G" | grep Zelda | cut -f2,5)" "Zelda DX - Links Awakening${TAB}1"
check "games: zelda save mtime set" "$([ "$(printf '%s\n' "$G" | grep Zelda | cut -f4)" -gt 0 ] && echo yes || echo no)" "yes"
check "games: dr mario no save" "$(printf '%s\n' "$G" | grep Mario | cut -f4,5)" "0${TAB}0"
GF=$(E game-files "$C" "Roms/1) Game Boy Color (GBC)/Zelda DX - Links Awakening.gbc" 1 1)
check "game_files: rom + save + state + thumb" "$(printf '%s\n' "$GF" | wc -l | tr -d ' ')" "4"
has "Saves/GBC/Zelda DX - Links Awakening.gbc.sav" "$GF"
has ".userdata/shared/GBC-gambatte/Zelda DX - Links Awakening.st0" "$GF"
GF2=$(E game-files "$C" "Roms/1) Game Boy Color (GBC)/Zelda DX - Links Awakening.gbc" 1 0)
nohas "Roms/1) Game Boy Color (GBC)/Zelda DX - Links Awakening.gbc" "$GF2"
GF3=$(E game-files "$C" "Roms/6) PlayStation (PS)/Final Fantasy VII" 1 1)
has "Roms/6) PlayStation (PS)/Final Fantasy VII" "$GF3"
has "Saves/PS/Final Fantasy VII.m3u.sav" "$GF3"
# build-export from a list file (names with spaces and parens must survive)
NET="$ROOT/skeleton/EXTRAS/Tools/tg5040/Device Sync.pak/sync-net.sh"
LIST="$WORK/pick.list"; printf '%s\n' "$GF" > "$LIST"
SV="$WORK/pick-serve"; sh "$NET" build-export "$C" "$SV" --list "$LIST" >/dev/null 2>&1
check "build-export --list: rom linked" "$(cat "$SV/Roms/1) Game Boy Color (GBC)/Zelda DX - Links Awakening.gbc" 2>/dev/null)" "ROM1"
check "build-export --list: state linked" "$(cat "$SV/.userdata/shared/GBC-gambatte/Zelda DX - Links Awakening.st0" 2>/dev/null)" "STATE"
check "build-export --list: manifest lists 4" "$(grep -c . "$SV/_dsync_manifest")" "4"

# ---- at-a-glance delta: plan-summary + plan-rich (games existence-only, saves/configs diffed) ----
export DS_MODE=ask   # the receiver's mode: a save that differs on both devices is a CONFLICT
DA="$WORK/delta-A"; DB="$WORK/delta-B"; mkdir -p "$DA" "$DB"
mk "$DA" "Saves/GBC/Zelda.gbc.sav"   "ZSAVE"                     # new on the receiver
mk "$DA" "Saves/GBC/Metroid.gbc.sav" "MSAVE-A"                   # differs on B -> CONFLICT
mk "$DA" "Roms/GBC/Zelda.gbc"        "ZROM"                      # game B lacks -> ADD
mk "$DA" "Roms/GBC/Metroid.gbc"      "MROM-A"                    # B has same name -> SKIP
mk "$DA" ".userdata/tg5040/GBC-gambatte/Zelda.cfg" "CFG"        # config, new -> ADD
mk "$DB" "Saves/GBC/Metroid.gbc.sav" "MSAVE-ON-B-DIFFERENT"      # save differs -> CONFLICT
mk "$DB" "Roms/GBC/Metroid.gbc"      "MROM-B-DIFFERENT-BYTES"    # same name, different bytes -> still SKIP
DMF="$WORK/delta-mf"; E manifest "$DA" > "$DMF"
DSUM=$(E plan-summary "$DMF" "$DB")
dval() { printf '%s\n' "$DSUM" | awk -F"$TAB" -v c="$1" -v f="$2" '$1==c{print $f}'; }
check "delta: rom items = 1 (missing only; same-name skipped)" "$(dval rom 2)" "1"
check "delta: save items = 2"                                  "$(dval save 2)" "2"
check "delta: save conflicts = 1"                             "$(dval save 6)" "1"
check "delta: config items = 1"                              "$(dval config 2)" "1"
check "delta: TOTAL items = 4"                               "$(dval TOTAL 2)" "4"
DRICH=$(E plan-rich "$DMF" "$DB")
check "delta: same-name ROM -> SKIP" "$(printf '%s\n' "$DRICH" | awk -F"$TAB" '$4=="Roms/GBC/Metroid.gbc"{print $1}')" "SKIP"
check "delta: missing ROM -> ADD"    "$(printf '%s\n' "$DRICH" | awk -F"$TAB" '$4=="Roms/GBC/Zelda.gbc"{print $1}')" "ADD"

# ---- bidirectional merge: one run leaves BOTH devices in sync (direction per file) ----
MA="$WORK/mA"; MB="$WORK/mB"; mkdir -p "$MA" "$MB"
mk "$MA" "Saves/GBC/only_a.sav"   "A-ONLY"                       # -> to-b
mk "$MA" "Saves/GBC/both.sav"     "SAVE-A-VERSION"               # differs -> conflict
mk "$MA" "Roms/GBC/rom_a.gbc"     "ROMA"                         # -> to-b
mk "$MA" "Roms/GBC/rom_both.gbc"  "ROM-BOTH-A"                   # present both -> skip
mk "$MA" ".userdata/tg5040/GBC-gambatte/cfg_a.cfg" "CFGA"       # -> to-b
mk "$MB" "Saves/GBC/only_b.sav"   "B-ONLY"                       # -> to-a
mk "$MB" "Saves/GBC/both.sav"     "SAVE-B-DIFFERENT"             # differs -> conflict
mk "$MB" "Roms/GBC/rom_both.gbc"  "ROM-BOTH-B-DIFFERENT-BYTES"   # present both, ROM -> skip (existence)
mk "$MB" "Roms/GBC/rom_b.gbc"     "ROMB"                         # -> to-a
MFA="$WORK/mfa"; MFB="$WORK/mfb"; E manifest "$MA" > "$MFA"; E manifest "$MB" > "$MFB"
MRG=$(E merge "$MFA" "$MFB")
mdir() { printf '%s\n' "$MRG" | awk -F"$TAB" -v r="$1" '$4==r{print $1}'; }
check "merge: A-only save -> to-b"   "$(mdir 'Saves/GBC/only_a.sav')" "to-b"
check "merge: B-only save -> to-a"   "$(mdir 'Saves/GBC/only_b.sav')" "to-a"
check "merge: differing save -> conflict" "$(mdir 'Saves/GBC/both.sav')" "conflict"
check "merge: A-only rom -> to-b"    "$(mdir 'Roms/GBC/rom_a.gbc')" "to-b"
check "merge: B-only rom -> to-a"    "$(mdir 'Roms/GBC/rom_b.gbc')" "to-a"
check "merge: rom on both -> skip"   "$(mdir 'Roms/GBC/rom_both.gbc')" "skip"
check "merge: A-only config -> to-b" "$(mdir '.userdata/tg5040/GBC-gambatte/cfg_a.cfg')" "to-b"
MSUM=$(E merge-summary "$MFA" "$MFB")
check "merge-summary: to-b TOTAL items = 3" "$(printf '%s\n' "$MSUM" | awk -F"$TAB" '$1=="to-b"&&$2=="TOTAL"{print $3}')" "3"
check "merge-summary: to-a TOTAL items = 2" "$(printf '%s\n' "$MSUM" | awk -F"$TAB" '$1=="to-a"&&$2=="TOTAL"{print $3}')" "2"

######################################################################
echo "########## SCENARIO W: wire format is FROZEN at DSYNC_PROTO=3 ##########"
# Everything a peer reads off the wire, pinned byte-for-byte: manifest lines, merge lines, the shared
# plan lines and the prefs line. If one of these checks fails, the wire SHAPE changed:
#   1. bump DSYNC_PROTO in launch.sh (all three platform copies stay byte-identical), and
#   2. update the expected strings AND the WIRE_PROTO below in the same commit.
# A shape change without a bump would let two builds sync by luck; the number is the only gate.
WIRE_PROTO=3
LAUNCH_W="$ROOT/skeleton/EXTRAS/Tools/tg5040/Device Sync.pak/launch.sh"
check "W: launch.sh publishes DSYNC_PROTO=$WIRE_PROTO" "$(sed -n 's/^DSYNC_PROTO=\([0-9]*\)$/\1/p' "$LAUNCH_W")" "$WIRE_PROTO"
check "W: prefs line carries S G C P F V" "$(grep -c "printf 'S=%s G=%s C=%s P=%s F=%s V=%s\\\\n'" "$LAUNCH_W")" "1"
for _p in miyoomini h700; do
	check "W: $_p launch.sh byte-identical to tg5040" "$(cmp -s "$LAUNCH_W" "$ROOT/skeleton/EXTRAS/Tools/$_p/Device Sync.pak/launch.sh" && echo same || echo differs)" "same"
	check "W: $_p sync-engine.sh byte-identical to tg5040" "$(cmp -s "$ENGINE" "$ROOT/skeleton/EXTRAS/Tools/$_p/Device Sync.pak/sync-engine.sh" && echo same || echo differs)" "same"
done
SW="$WORK/sw"; WA="$SW/a"; WB="$SW/b"; mkdir -p "$WA" "$WB"
mk "$WA" "Saves/GBA/Zelda.srm" "AAAA"
mk "$WA" "Roms/1) Game Boy Advance (GBA)/Zelda.gba" "ROM"
mk "$WA" ".userdata/tg5040/GBA-mgba/minarch.cfg" "CFG"
mk "$WB" "Saves/GBA/Zelda.srm" "BBBBBB"
mk "$WB" "Saves/GBC/Tetris.sav" "CC"
find "$SW" -type f -exec env TZ=UTC touch -t 202601011200 {} +     # 1767268800, timezone-proof
TZ=UTC touch -t 202601021200 "$WB/Saves/GBA/Zelda.srm"              # 1767355200: B's save is newer
E manifest "$WA" | sort > "$SW/a.mf"; E manifest "$WB" | sort > "$SW/b.mf"
check "W: manifest line = REL SIZE MTIME CLASS HASH (ROM mtime 0, hash -)" "$(cat "$SW/a.mf")" \
"$(printf '.userdata/tg5040/GBA-mgba/minarch.cfg\t3\t1767268800\tconfig\t-\nRoms/1) Game Boy Advance (GBA)/Zelda.gba\t3\t0\trom\t-\nSaves/GBA/Zelda.srm\t4\t1767268800\tsave\t-')"
check "W: manifest B" "$(cat "$SW/b.mf")" \
"$(printf 'Saves/GBA/Zelda.srm\t6\t1767355200\tsave\t-\nSaves/GBC/Tetris.sav\t2\t1767268800\tsave\t-')"
E merge "$SW/a.mf" "$SW/b.mf" | sort > "$SW/merge"
check "W: merge line = DIRECTION CLASS SIZE REL (order is not part of the contract)" "$(cat "$SW/merge")" \
"$(printf 'conflict\tsave\t6\tSaves/GBA/Zelda.srm\nto-a\tsave\t2\tSaves/GBC/Tetris.sav\nto-b\tconfig\t3\t.userdata/tg5040/GBA-mgba/minarch.cfg\nto-b\trom\t3\tRoms/1) Game Boy Advance (GBA)/Zelda.gba')"
# the shared plan the host publishes as _dsync_plan: build_plan lives in launch.sh (pure awk), lifted out
awk '/^build_plan\(\)\{/{p=1} p{print} p&&/"\$1"; }$/{exit}' "$LAUNCH_W" > "$SW/build_plan.sh"
check "W: build_plan extracted from launch.sh" "$(grep -c '^build_plan' "$SW/build_plan.sh")" "1"
printf 'Saves/GBA/Zelda.srm\tb\n' > "$SW/dec"   # the user picked B on the conflict
( . "$SW/build_plan.sh"; build_plan "$SW/merge" "$SW/dec" "" to-a "$SW/a.mf" "$SW/b.mf" | sort > "$SW/plan.a"
  build_plan "$SW/merge" "$SW/dec" "" to-b "$SW/a.mf" "$SW/b.mf" | sort > "$SW/plan.b" )
check "W: plan line = take CLASS SIZE REL HASH MTIME (to-a: B copies, B mtimes)" "$(cat "$SW/plan.a")" \
"$(printf 'take\tsave\t2\tSaves/GBC/Tetris.sav\t-\t1767268800\ntake\tsave\t6\tSaves/GBA/Zelda.srm\t-\t1767355200')"
check "W: plan to-b (A copies, ROM mtime 0)" "$(cat "$SW/plan.b")" \
"$(printf 'take\tconfig\t3\t.userdata/tg5040/GBA-mgba/minarch.cfg\t-\t1767268800\ntake\trom\t3\tRoms/1) Game Boy Advance (GBA)/Zelda.gba\t-\t0')"
# and the plan feeds apply-plan unchanged (the consumer side of the same contract)
check "W: apply-plan accepts the frozen plan" "$(cp -R "$WB" "$SW/bstage"; E apply-plan "$SW/plan.a" "$SW/bstage" "$SW/adst" "$SW/bk/1" >/dev/null 2>&1 && cat "$SW/adst/Saves/GBA/Zelda.srm" "$SW/adst/Saves/GBC/Tetris.sav")" "BBBBBBCC"

######################################################################
echo "########## SCENARIO K: merge takes the clock offset for every class ##########"
# CLK_OFF (A clock minus B clock) used to reach only save conflicts; configs/recents took the raw newest.
SK="$WORK/sk"; mkdir -p "$SK"
printf '.userdata/tg5040/GBA-mgba/minarch.cfg\t3\t1767268800\tconfig\t-\n' > "$SK/a.mf"
printf '.userdata/tg5040/GBA-mgba/minarch.cfg\t4\t1767268900\tconfig\t-\n' > "$SK/b.mf"
check "K: raw clocks: B is 100 s newer -> to-a" "$(E merge "$SK/a.mf" "$SK/b.mf" | cut -f1)" "to-a"
check "K: A runs 200 s behind B (off=-200): B is really older -> to-b" "$(E merge "$SK/a.mf" "$SK/b.mf" -200 | cut -f1)" "to-b"
check "K: off=+200 keeps to-a" "$(E merge "$SK/a.mf" "$SK/b.mf" 200 | cut -f1)" "to-a"
# FAT32 rounding: same size, mtimes 1 s apart = the same file (a stamped odd second reads back even)
printf 'Saves/GBA/f.srm\t8\t1767268801\tsave\t-\n' > "$SK/fa.mf"
printf 'Saves/GBA/f.srm\t8\t1767268800\tsave\t-\n' > "$SK/fb.mf"
check "K: same size, mtime 1 s apart -> skip (FAT 2 s window)" "$(E merge "$SK/fa.mf" "$SK/fb.mf" | cut -f1)" "skip"
printf 'Saves/GBA/f.srm\t8\t1767268803\tsave\t-\n' > "$SK/fc.mf"
check "K: same size, mtime 3 s apart -> conflict" "$(E merge "$SK/fc.mf" "$SK/fb.mf" | cut -f1)" "conflict"
printf 'Saves/GBA/f.srm\t8\t1767268802\tsave\t-\n' > "$SK/fd.mf"
check "K: same size, mtime 2 s apart -> conflict (only the FAT round-down is tolerated)" "$(E merge "$SK/fd.mf" "$SK/fb.mf" | cut -f1)" "conflict"
# aboot: A's own file predates A's boot -> raw (the Miyoo hosts as A, so its lag matters on this side too)
check "K: off=-200, A file older than A boot -> raw -> to-a" "$(E merge "$SK/a.mf" "$SK/b.mf" -200 0 1767268850 | cut -f1)" "to-a"
# pboot: B booted (B clock) AFTER this file was written, so its lag is unknown: compared raw -> to-a
check "K: off=-200 but file predates B boot -> raw -> to-a" "$(E merge "$SK/a.mf" "$SK/b.mf" -200 1767268950 | cut -f1)" "to-a"
check "K: off=-200, file written after B boot -> corrected -> to-b" "$(E merge "$SK/a.mf" "$SK/b.mf" -200 1767268000 | cut -f1)" "to-b"
######################################################################
echo "########## SCENARIO T: a truncated staged file is never applied ##########"
# FAT after a power cut leaves the last staged files zero-length; apply used to verify the tmp against
# THAT file and wrote 0 bytes over the save with a clean COMPLETE.
ST="$WORK/st"; LT="$ST/local"; STT="$ST/staging"; BKT="$ST/bk/20260920-2300"; mkdir -p "$LT" "$STT"
mk "$LT"  "Saves/GBA/z.srm" "LIVE-25-BYTES-OF-PROGRESS"
mk "$STT" "Saves/GBA/z.srm" "FULL-STAGED-COPY"
PLANT="$ST/plan"; planln "$STT" save "Saves/GBA/z.srm" 1700000000 > "$PLANT"
: > "$STT/Saves/GBA/z.srm"     # truncated AFTER the plan was written
E apply-plan "$PLANT" "$STT" "$LT" "$BKT" >/dev/null 2>&1; trc=$?
check "T: apply refuses (rc 1)"                 "$trc" "1"
check "T: the live save is untouched"          "$(cat "$LT/Saves/GBA/z.srm")" "LIVE-25-BYTES-OF-PROGRESS"
check "T: journal is NOT complete"             "$(E journal-status "$BKT" | cut -d"$TAB" -f1)" "INCOMPLETE"

######################################################################
echo "########## SCENARIO U: Favorites and Collections are MERGED, not replaced ##########"
SU="$WORK/su"; UA="$SU/a"; UB="$SU/b"; mkdir -p "$UA" "$UB"
FAV=".userdata/shared/.minui/favorites.txt"; COL="Collections/Best.txt"
mkdir -p "$UA/.userdata/shared/.minui" "$UB/.userdata/shared/.minui" "$UA/Collections" "$UB/Collections"
printf 'Roms/GBA/b.gba\nRoms/GBA/a.gba\n' > "$UA/$FAV"; printf 'Roms/GBA/c.gba\nRoms/GBA/a.gba\n' > "$UB/$FAV"
printf 'Roms/GB/x.gb\n' > "$UA/$COL"; printf 'Roms/GB/y.gb\n' > "$UB/$COL"
TZ=UTC touch -t 202601011200 "$UA/$FAV" "$UA/$COL"; TZ=UTC touch -t 202601021200 "$UB/$FAV" "$UB/$COL"
E manifest "$UA" > "$SU/a.mf"; E manifest "$UB" > "$SU/b.mf"
MU=$(E merge "$SU/a.mf" "$SU/b.mf")
check "U: favorites go BOTH ways" "$(printf '%s\n' "$MU" | awk -F"$TAB" '$4 ~ /favorites/ {print $1}' | sort | tr '\n' ' ')" "to-a to-b "
check "U: collection goes BOTH ways" "$(printf '%s\n' "$MU" | awk -F"$TAB" '$4 ~ /Best/ {print $1}' | sort | tr '\n' ' ')" "to-a to-b "
# apply on A with B's copies staged, and on B with A's
STA="$SU/sta"; STB="$SU/stb"; mkdir -p "$STA" "$STB"; cp -R "$UB/." "$STA/"; cp -R "$UA/." "$STB/"
PLA="$SU/plan.a"; { planln "$STA" favorite "$FAV" 1767355200; planln "$STA" collection "$COL" 1767355200; } > "$PLA"
PLB="$SU/plan.b"; { planln "$STB" favorite "$FAV" 1767268800; planln "$STB" collection "$COL" 1767268800; } > "$PLB"
E apply-plan "$PLA" "$STA" "$UA" "$SU/bk/a" >/dev/null 2>&1; E apply-plan "$PLB" "$STB" "$UB" "$SU/bk/b" >/dev/null 2>&1
check "U: A favorites = union, sorted" "$(cat "$UA/$FAV" | tr '\n' ' ')" "Roms/GBA/a.gba Roms/GBA/b.gba Roms/GBA/c.gba "
check "U: B favorites = the same bytes"  "$(cat "$UB/$FAV" | tr '\n' ' ')" "Roms/GBA/a.gba Roms/GBA/b.gba Roms/GBA/c.gba "
check "U: collection union on both" "$(cat "$UA/$COL" | tr '\n' ' ')/$(cat "$UB/$COL" | tr '\n' ' ')" "Roms/GB/x.gb Roms/GB/y.gb /Roms/GB/x.gb Roms/GB/y.gb "
check "U: pre-union favorites are backed up on A" "$(cat "$SU/bk/a/$FAV" | tr '\n' ' ')" "Roms/GBA/b.gba Roms/GBA/a.gba "
E manifest "$UA" > "$SU/a2.mf"; E manifest "$UB" > "$SU/b2.mf"
check "U: after the merge both sides read identical (skip)" "$(E merge "$SU/a2.mf" "$SU/b2.mf" | awk -F"$TAB" '{print $1}' | sort -u | tr '\n' ' ')" "skip "

echo ""
echo "RESULT: $PASS passed, $FAIL failed"
rm -rf "$WORK"
[ "$FAIL" -eq 0 ]
