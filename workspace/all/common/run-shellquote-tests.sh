#!/bin/sh
# Host test for minui's shellQuote(). No device, no toolchain, no SDL.
#
# The function is EXTRACTED from minui.c rather than duplicated, so the test can never drift from
# the shipping implementation. Built under AddressSanitizer: the bug this replaces was a buffer
# overrun, so a single byte past the end must fail the suite rather than pass quietly.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
SRC="$HERE/../minui/minui.c"
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

[ -f "$SRC" ] || { echo "cannot find minui.c at $SRC"; exit 1; }

# Pull out the two size constants and the function body verbatim. QUOTED_MAX is sized from MAX_PATH since the
# long-path fixes (383defa1), so take that from defines.h too.
{
	grep -E '^#define MAX_PATH ' "$HERE/defines.h"
	grep -E '^#define (QUOTED_MAX|CMD_MAX)' "$SRC"
	awk '/^static int shellQuote\(/,/^}/' "$SRC"
} > "$OUT/shellquote_extracted.h"

LINES=$(wc -l < "$OUT/shellquote_extracted.h" | tr -d ' ')
[ "$LINES" -gt 10 ] || { echo "extraction failed — shellQuote not found in minui.c"; exit 1; }
grep -q 'QUOTED_MAX' "$OUT/shellquote_extracted.h" || { echo "extraction missed QUOTED_MAX"; exit 1; }

cc -std=gnu99 -g -fsanitize=address -fno-omit-frame-pointer \
   -I"$OUT" "$HERE/shellquote_test.c" -o "$OUT/shellquote_test"
"$OUT/shellquote_test"
