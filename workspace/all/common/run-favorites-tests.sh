#!/bin/sh
# Host test for Favorites, end to end on a clean card: minarch keys the running game (Game_findM3U),
# utils.c writes and reads the list (Favorites_toggle / Favorites_has), the launcher decides whether
# the Favorites row shows (hasFavorites). No device, no toolchain, no SDL.
#
# Every piece is EXTRACTED from the shipping sources, never copied, so the test cannot drift. The
# one thing it has to mirror is minarch's key expression; the grep below fails the run if that
# expression or Game_open's use of Game_findM3U ever changes, so the mirror gets revisited.
#
# Why this exists: v1.8.0/v1.8.1 shipped a favorites key that named a file that never exists, so
# every single-disc game in a folder shared one entry and the Favorites row never appeared. Every
# test device already had favorites saved under the older, correct key, so nobody saw it
# (r/trimui, 2026-09-28). This test starts from an empty card on purpose.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
MINARCH="$HERE/../minarch/minarch.c"
MINUI="$HERE/../minui/minui.c"
UTILS="$HERE/utils.c"
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

grep -qF 'Game_findM3U(game.path, game.m3u_path, sizeof(game.m3u_path));' "$MINARCH" || { echo "Game_open no longer fills game.m3u_path via Game_findM3U: update favorites_test.c"; exit 1; }
grep -qF 'Favorites_toggle(game.m3u_path[0] ? game.m3u_path : game.path);' "$MINARCH" || { echo "minarch's favorites key expression changed: update favorites_key() in favorites_test.c"; exit 1; }

{
	grep -E '^#define (MAX_PATH|SHARED_USERDATA_PATH|FAVORITE_PATH) ' "$HERE/defines.h"
	awk '/^void normalizeNewline\(/,/^}/' "$UTILS"
	awk '/^void trimTrailingNewlines\(/,/^}/' "$UTILS"
	awk '/^int exists\(char\* path\) \{/,/^}/' "$UTILS"
	awk '/^static const char\* Favorites_rel\(/,/^}/' "$UTILS"
	awk '/^int Favorites_has\(/,/^}/' "$UTILS"
	awk '/^void Favorites_toggle\(/,/^}/' "$UTILS"
	awk '/^static int Game_findM3U\(/,/^}/' "$MINARCH"
	awk '/^static int hasFavorites\(void\) \{/,/^}/' "$MINUI"
} > "$OUT/favorites_extracted.h"

for SYM in 'define MAX_PATH ' 'define SHARED_USERDATA_PATH ' 'define FAVORITE_PATH ' normalizeNewline trimTrailingNewlines exists Favorites_rel Favorites_has Favorites_toggle Game_findM3U hasFavorites; do
	case "$SYM" in define*) PAT="$SYM" ;; *) PAT="$SYM(" ;; esac
	grep -qF "$PAT" "$OUT/favorites_extracted.h" || { echo "extraction missed $SYM"; exit 1; }
done

# SDCARD_PATH is pasted into string literals (FAVORITE_PATH), so it has to be a literal too: the temp card root.
SD="$OUT/sd"
mkdir -p "$SD"
cc -std=gnu99 -g -fsanitize=address -fno-omit-frame-pointer -Wall -Wno-deprecated-declarations \
   -DSDCARD_PATH="\"$SD\"" -I"$OUT" "$HERE/favorites_test.c" -o "$OUT/favorites_test"
"$OUT/favorites_test"
