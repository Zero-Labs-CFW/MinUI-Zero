#!/bin/sh
# Host test harness for the Device Sync engine (Phase 1, transport-blind). Zero hardware.
# Proves: never-lose-a-save (backup + exact undo), never-delete, never-overwrite-a-ROM,
# clock-skew-safe merge, atomic writes, and filenames with spaces.
# Run: make test-devicesync   (or: sh workspace/all/common/run-devicesync-tests.sh)
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
ENGINE="$ROOT/skeleton/SYSTEM/tg5040/paks/tools-stash/Device Sync.pak/sync-engine.sh"
[ -f "$ENGINE" ] || { echo "engine not found: $ENGINE" >&2; exit 2; }
TAB=$(printf '\t')
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got [$2] want [$3])"; fi; }
has()   { if printf '%s\n' "$2" | grep -qF "$1"; then ok "plan: $1"; else bad "plan missing: $1"; fi; }
nohas() { if printf '%s\n' "$2" | grep -qF "$1"; then bad "plan should NOT have: $1"; else ok "plan omits: $1"; fi; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/dsync-test.XXXXXX")
A="$WORK/incoming"; B="$WORK/local"; BK="$WORK/backup/20260903-1200"; REF="$WORK/local-ref"
mkdir -p "$A" "$B"

mk() { # mk <dir> <relpath> <content> [mtime YYYYMMDDhhmm]
	mkdir -p "$1/$(dirname "$2")"; printf '%s' "$3" > "$1/$2"
	[ $# -ge 4 ] && touch -t "$4" "$1/$2"
}

# --- two trees exercising every merge rule ---
mk "$A" "Roms/GBA/game1.gba" "IDENTICAL-ROM"          ; mk "$B" "Roms/GBA/game1.gba" "IDENTICAL-ROM"        # SKIP
mk "$A" "Roms/GBA/game2.gba" "NEW-ROM-ONLY-IN-A"                                                            # ADD
mk "$A" "Roms/GBA/game3.gba" "ROM-VERSION-AAAA"       ; mk "$B" "Roms/GBA/game3.gba" "ROM-VERSION-B"        # CONFLICT-ROM
mk "$A" "Roms/Game Boy Advance/Metroid Fusion (USA).gba" "SPACEY"                                           # ADD (spaces)
mk "$A" "Saves/GBA/save1.srm" "NEW-SAVE-ONLY-IN-A"                                                          # ADD
mk "$A" "Saves/GBA/save2.srm" "A-IS-NEWER-CONTENT" 202602010000 ; mk "$B" "Saves/GBA/save2.srm" "B-OLD-CONTENT" 202601010000  # UPDATE
mk "$A" "Saves/GBA/save3.srm" "A-OLD-CONTENT" 202601010000      ; mk "$B" "Saves/GBA/save3.srm" "B-IS-NEWER-CONTENT" 202602010000 # KEEP-LOCAL
mk "$A" "Saves/GBA/save4.srm" "SAME-SAVE"             ; mk "$B" "Saves/GBA/save4.srm" "SAME-SAVE"           # SKIP (identical)
mk "$B" "Saves/GBA/localonly.srm" "ONLY-ON-B-NEVER-DELETE"                                                  # untouched

cp -R "$B" "$REF"   # pre-sync reference for the undo comparison

echo "== plan =="
P=$(sh "$ENGINE" plan "$A" "$B")
printf '%s\n' "$P" | sed 's/^/    /'
has  "ADD${TAB}Roms/GBA/game2.gba" "$P"
has  "SKIP${TAB}Roms/GBA/game1.gba" "$P"
has  "CONFLICT-ROM${TAB}Roms/GBA/game3.gba" "$P"
has  "ADD${TAB}Roms/Game Boy Advance/Metroid Fusion (USA).gba" "$P"
has  "ADD${TAB}Saves/GBA/save1.srm" "$P"
has  "UPDATE${TAB}Saves/GBA/save2.srm" "$P"
has  "KEEP-LOCAL${TAB}Saves/GBA/save3.srm" "$P"
has  "SKIP${TAB}Saves/GBA/save4.srm" "$P"
nohas "localonly.srm" "$P"

echo "== apply =="
sh "$ENGINE" apply "$A" "$B" "$BK"
check "game2 added"                "$(cat "$B/Roms/GBA/game2.gba")"                              "NEW-ROM-ONLY-IN-A"
check "spacey rom added"           "$(cat "$B/Roms/Game Boy Advance/Metroid Fusion (USA).gba")" "SPACEY"
check "ROM conflict kept local"    "$(cat "$B/Roms/GBA/game3.gba")"                              "ROM-VERSION-B"
check "save1 added"                "$(cat "$B/Saves/GBA/save1.srm")"                             "NEW-SAVE-ONLY-IN-A"
check "save2 updated to A"         "$(cat "$B/Saves/GBA/save2.srm")"                             "A-IS-NEWER-CONTENT"
check "save2 loser BACKED UP"      "$(cat "$BK/Saves/GBA/save2.srm")"                            "B-OLD-CONTENT"
check "save3 kept local (newer)"   "$(cat "$B/Saves/GBA/save3.srm")"                             "B-IS-NEWER-CONTENT"
check "save4 untouched"            "$(cat "$B/Saves/GBA/save4.srm")"                             "SAME-SAVE"
check "B-only file NOT deleted"    "$(cat "$B/Saves/GBA/localonly.srm")"                         "ONLY-ON-B-NEVER-DELETE"
if [ -e "$B/Roms/GBA/game2.gba.dsync.tmp" ]; then bad "temp file left behind"; else ok "no temp files left"; fi

echo "== undo =="
sh "$ENGINE" undo "$B" "$BK"
if diff -r "$REF" "$B" >/dev/null 2>&1; then ok "undo restored EXACT pre-sync state"; else bad "undo did not restore pre-sync state"; diff -r "$REF" "$B" | sed 's/^/    /'; fi

echo "== prune (keep newest 5 of 7) =="
PR="$WORK/backups"; mkdir -p "$PR"
for d in 20260101-0000 20260102-0000 20260103-0000 20260104-0000 20260105-0000 20260106-0000 20260107-0000; do mkdir -p "$PR/$d"; done
sh "$ENGINE" prune "$PR" 5
check "prune leaves 5"             "$(ls -1 "$PR" | wc -l | tr -d ' ')" "5"
if [ -d "$PR/20260107-0000" ] && [ ! -d "$PR/20260101-0000" ]; then ok "prune kept newest, dropped oldest"; else bad "prune kept the wrong set"; fi

echo ""
echo "RESULT: $PASS passed, $FAIL failed"
rm -rf "$WORK"
[ "$FAIL" -eq 0 ]
