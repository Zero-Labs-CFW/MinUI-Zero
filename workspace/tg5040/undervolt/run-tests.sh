#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
mkdir -p "$ROOT/.notes"
TMP=$(mktemp -d "$ROOT/.notes/uvmap-test.XXXXXX")
trap 'rc=$?; rm -rf "$TMP"; exit $rc' EXIT HUP INT TERM  # preserve the status the trap used to mask

UV_SCRIPT="$ROOT/workspace/tg5040/undervolt/uvmap.sh"
TOOL_SCRIPT="$ROOT/skeleton/SYSTEM/tg5040/paks/Optimize CPU.pak/launch.sh"
RECEIPT="$ROOT/docs/bench/receipts/uv-calibration"

cp "$RECEIPT/margins.log" "$TMP/margins.log"
LOG="$TMP/margins.log"
BASE=712500
STEP=12500
FLOOR=762500
STOCK_MAX=1187500

# Load the actual validator functions without executing uvmap's device-only main body.
eval "$(sed -n '/^is_uint()/,/^on_step()/p; /^stock_for_opp()/,/^}/p; /^has_any_verdict()/,/^}/p; /^record_floor_done()/,/^}/p; /^verdict_for()/,/^}/p' "$UV_SCRIPT")"

for opp in 408000 600000 816000 1008000 1200000 1416000 1608000 1800000; do
	verdict_for "$opp" >/dev/null
done
printf '%s\n' '1800000 CLIFF garbage' >> "$LOG"
if verdict_for 1800000 >/dev/null 2>&1; then
	echo "duplicate malformed verdict was accepted" >&2
	exit 1
fi

LOG="$TMP/floor-verdict.log"
: > "$LOG"
if record_floor_done 1008000 0; then
	echo "unproven floor was recorded as DONE" >&2
	exit 1
fi
[ ! -s "$LOG" ]
printf '%s\n' '1008000 CLIFF 762500 (stress-fail)' > "$LOG"
if record_floor_done 1008000 1; then
	echo "DONE was appended over a floor CLIFF" >&2
	exit 1
fi
[ "$(wc -l < "$LOG" | tr -d ' ')" = "1" ]
: > "$LOG"
record_floor_done 1008000 1
grep -qx '1008000 DONE floor 762500 reached, no cliff' "$LOG"
LOG="$TMP/margins.log"

eval "$(sed -n '/^load_calibration()/,/^}/p; /^valid_table()/,/^}/p' "$TOOL_SCRIPT")"
UV_DIR="$TMP"
CHIP_DIR="$TMP"   # the tool's table/calibration readers resolve the per-chip slot
cp "$RECEIPT/table.conf" "$TMP/table.conf"
cp "$RECEIPT/table.stock" "$TMP/table.stock"
cp "$RECEIPT/calibration" "$TMP/calibration"
valid_table
load_calibration
[ "$calibrated" = "2026-07-11" ]
[ "$min_margin_mv" = "25" ]
[ "$top_reduction_mv" = "112" ]

printf '%s\n' '1800000 1187500' >> "$TMP/table.conf"
if valid_table; then
	echo "table with an extra row was accepted" >&2
	exit 1
fi

cp "$RECEIPT/table.conf" "$TMP/table.conf"
sed 's/^1008000 812500$/1008000 912500/' "$TMP/table.conf" > "$TMP/table.bad"
mv "$TMP/table.bad" "$TMP/table.conf"
if valid_table; then
	echo "table row above recorded stock was accepted" >&2
	exit 1
fi

cp "$RECEIPT/table.conf" "$TMP/table.conf"
sed 's/^1800000 1075000$/1800000 1062500/' "$TMP/table.conf" > "$TMP/table.bad"
mv "$TMP/table.bad" "$TMP/table.conf"
if valid_table; then
	echo "non-monotonic ceiling envelope was accepted" >&2
	exit 1
fi

cp "$RECEIPT/table.conf" "$TMP/table.conf"
cp "$RECEIPT/table.stock" "$TMP/table.stock"
sed 's/^816000 762500$/816000 775000/' "$TMP/table.stock" > "$TMP/table.bad"
mv "$TMP/table.bad" "$TMP/table.stock"
if valid_table; then
	echo "light-load table row below recorded stock was accepted" >&2
	exit 1
fi

cp "$RECEIPT/calibration" "$TMP/calibration"
printf '%s\n' 'touch=/tmp/should-not-run' >> "$TMP/calibration"
if load_calibration; then
	echo "calibration with an unknown field was accepted" >&2
	exit 1
fi

echo "== undervolt data tests: ALL PASS =="
