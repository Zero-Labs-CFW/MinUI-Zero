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
ENGINE="$ROOT/skeleton/SYSTEM/tg5040/paks/tools-stash/Device Sync.pak/sync-engine.sh"
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
	mk "$A" "Roms/GBA/game3.gba" "ROM-VERSION-AAAA"     ; mk "$B" "Roms/GBA/game3.gba" "ROM-VERSION-B"      # CONFLICT-ROM
	mk "$A" "Roms/Game Boy Advance/Metroid Fusion (USA).gba" "SPACEY"                                       # ADD (spaces)
	mk "$A" "Saves/GBA/save1.srm" "NEW-SAVE-ONLY-IN-A"                                                      # ADD
	mk "$A" "Saves/GBA/save2.srm" "A-IS-NEWER-CONTENT" 202602010000 ; mk "$B" "Saves/GBA/save2.srm" "B-OLD-CONTENT" 202601010000  # UPDATE
	mk "$A" "Saves/GBA/save3.srm" "A-OLD-CONTENT" 202601010000      ; mk "$B" "Saves/GBA/save3.srm" "B-IS-NEWER-CONTENT" 202602010000 # KEEP-LOCAL
	mk "$A" "Saves/GBA/save4.srm" "SAME-SAVE"           ; mk "$B" "Saves/GBA/save4.srm" "SAME-SAVE"         # SKIP (identical)
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
SAVEHASH=$(printf '%s\n' "$M" | grep 'save4.srm' | cut -f5)
if [ -n "$SAVEHASH" ] && [ "$SAVEHASH" != "-" ]; then ok "save hash present ($SAVEHASH)"; else bad "save hash missing"; fi

echo "== plan =="
P=$(E plan "$A" "$B"); printf '%s\n' "$P" | sed 's/^/    /'
has  "ADD${TAB}Roms/GBA/game2.gba" "$P"
has  "SKIP${TAB}Roms/GBA/game1.gba" "$P"
has  "CONFLICT-ROM${TAB}Roms/GBA/game3.gba" "$P"
has  "ADD${TAB}Roms/Game Boy Advance/Metroid Fusion (USA).gba" "$P"
has  "UPDATE${TAB}Saves/GBA/save2.srm" "$P"
has  "KEEP-LOCAL${TAB}Saves/GBA/save3.srm" "$P"
has  "SKIP${TAB}Saves/GBA/save4.srm" "$P"
nohas "localonly.srm" "$P"

echo "== apply =="; E apply "$A" "$B" "$BK"; assert_applied "$B" "$BK"
echo "== undo =="
E undo "$B" "$BK"
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
nohas "game3.gba" "$DL"   # CONFLICT-ROM: not downloaded
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
E undo "$B2" "$BK2"
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
E undo "$B3b" "$BK3b" 2>/dev/null
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
OMT=$(mt "$B3e/Saves/GBA/m.srm"); E apply "$A3e" "$B3e" "$BK3e"; E undo "$B3e" "$BK3e"
check "E: undo restored original content" "$(cat "$B3e/Saves/GBA/m.srm")" "M-OLD"
check "E: undo restored original mtime"   "$(mt "$B3e/Saves/GBA/m.srm")" "$OMT"

echo "== F: undo of an ADD keeps a file the user changed after the sync =="
A3f="$WORK/s3f/sender"; B3f="$WORK/s3f/local"; BK3f="$WORK/s3f/bk"; mkdir -p "$A3f" "$B3f"
mk "$A3f" "Saves/GBA/new1.srm" "ADDED"; mk "$A3f" "Saves/GBA/new2.srm" "ADDED2"
E apply "$A3f" "$B3f" "$BK3f"
printf 'USER-EDITED-BIGGER' > "$B3f/Saves/GBA/new1.srm"
E undo "$B3f" "$BK3f" 2>/dev/null
check "F: undo kept user-edited ADD"   "$(cat "$B3f/Saves/GBA/new1.srm" 2>/dev/null)" "USER-EDITED-BIGGER"
check "F: undo removed untouched ADD"  "$([ -e "$B3f/Saves/GBA/new2.srm" ] && echo present || echo removed)" "removed"

######################################################################
echo "########## SCENARIO 4: push mode (DS_MODE=push -- directional send, sender wins) ##########"
A4="$WORK/s4/sender"; B4="$WORK/s4/local"; BK4="$WORK/s4/bk"; build_trees "$A4" "$B4"
MF4="$WORK/s4.manifest"; DS_MODE=push sh "$ENGINE" manifest "$A4" > "$MF4"
P4=$(DS_MODE=push sh "$ENGINE" plan-net "$MF4" "$B4"); printf '%s\n' "$P4" | sed 's/^/    /'
has "UPDATE${TAB}Saves/GBA/save2.srm" "$P4"       # sender newer -> UPDATE
has "UPDATE${TAB}Saves/GBA/save3.srm" "$P4"       # local newer, but PUSH -> sender still wins
has "SKIP${TAB}Saves/GBA/save4.srm" "$P4"         # identical -> still skipped (no needless copy)
has "CONFLICT-ROM${TAB}Roms/GBA/game3.gba" "$P4"  # ROMs still additive, never overwritten
ST4="$WORK/s4/staging"; mkdir -p "$ST4"
DS_MODE=push sh "$ENGINE" delta "$MF4" "$B4" | while IFS= read -r rel; do [ -n "$rel" ] || continue; mkdir -p "$ST4/$(dirname "$rel")"; cp "$A4/$rel" "$ST4/$rel"; done
DS_MODE=push sh "$ENGINE" apply-net "$MF4" "$ST4" "$B4" "$BK4"
check "push: local-newer save OVERWRITTEN by sender" "$(cat "$B4/Saves/GBA/save3.srm")"        "A-OLD-CONTENT"
check "push: the overwritten local save is backed up" "$(cat "$BK4/Saves/GBA/save3.srm")"      "B-IS-NEWER-CONTENT"
check "push: identical save left untouched"           "$(cat "$B4/Saves/GBA/save4.srm")"       "SAME-SAVE"
check "push: ROM conflict still kept local"           "$(cat "$B4/Roms/GBA/game3.gba")"        "ROM-VERSION-B"
check "push: local-only file NOT deleted"             "$(cat "$B4/Saves/GBA/localonly.srm")"   "ONLY-ON-B-NEVER-DELETE"

######################################################################
echo "########## prune ##########"
PR="$WORK/backups"; mkdir -p "$PR"
for d in 20260101-0000 20260102-0000 20260103-0000 20260104-0000 20260105-0000 20260106-0000 20260107-0000; do mkdir -p "$PR/$d"; done
E prune "$PR" 5
check "prune leaves 5" "$(ls -1 "$PR" | wc -l | tr -d ' ')" "5"
if [ -d "$PR/20260107-0000" ] && [ ! -d "$PR/20260101-0000" ]; then ok "prune kept newest, dropped oldest"; else bad "prune kept the wrong set"; fi

echo ""
echo "RESULT: $PASS passed, $FAIL failed"
rm -rf "$WORK"
[ "$FAIL" -eq 0 ]
