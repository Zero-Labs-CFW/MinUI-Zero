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

# --- tool screens: an armed campaign must always offer a cancel that works ---
# Stand-ins for confirm.elf/say.elf that read their arguments the way
# workspace/all/confirm/confirm.c does and answer from a scripted list of presses. A press
# on a button the screen does not offer is ignored, as on the device; running out of
# presses means the user is stuck on that screen.
BIN="$TMP/bin"
mkdir -p "$BIN"
cat > "$BIN/confirm.elf" <<'EOF'
#!/bin/sh
ok=0
if [ "${1-}" = "--ok" ]; then ok=1; shift; [ "$#" -gt 0 ] && shift; fi
a=${2-CONFIRM}; b=${3-CANCEL}; x=${4-}
echo "confirm ok=$ok a=[$a] b=[$b] x=[$x]" >> "$UI_LOG"
while :; do
	p=$(head -1 "$UI_PRESSES" 2>/dev/null)
	[ -n "$p" ] || exit 99
	tail -n +2 "$UI_PRESSES" > "$UI_PRESSES.tmp"; mv "$UI_PRESSES.tmp" "$UI_PRESSES"
	case "$p" in
		A) [ -n "$a" ] && exit 0 ;;
		B) exit 1 ;;
		X) [ -n "$x" ] && exit 2 ;;
	esac
done
EOF
printf '%s\n' '#!/bin/sh' 'echo "say [$(printf "%s" "$1" | head -1)]" >> "$UI_LOG"' > "$BIN/say.elf"
printf '%s\n' '#!/bin/sh' 'exit 0' > "$BIN/sync"
chmod +x "$BIN/confirm.elf" "$BIN/say.elf" "$BIN/sync"
UI_LOG="$TMP/ui.log"
UI_PRESSES="$TMP/ui.presses"
export UI_LOG UI_PRESSES

eval "$(sed -n '/^armed_screen()/,/^}/p' "$TOOL_SCRIPT")"
if ! type armed_screen > /dev/null 2>&1; then
	echo "tool has no armed_screen(): the armed screens are not testable" >&2
	exit 1
fi

armed_press() { # armed_press "<presses>": show the armed screen to a user pressing these buttons
	: > "$UI_LOG"
	printf '%s\n' $1 > "$UI_PRESSES"
	touch "$TMP/ARMED"
	if ! ( PATH="$BIN:$PATH"; armed_screen "Measuring... 0 of 8 steps done." ); then
		echo "armed screen left the user stuck after: $1" >&2
		cat "$UI_LOG" >&2
		exit 1
	fi
}

armed_press "X A"
if [ -f "$TMP/ARMED" ]; then
	echo "CANCEL then CANCEL IT left the campaign armed" >&2
	cat "$UI_LOG" >&2
	exit 1
fi
# the pills the user sees: B backs out, X cancels, A is not offered
if [ "$(head -1 "$UI_LOG")" != "confirm ok=0 a=[] b=[BACK] x=[CANCEL]" ]; then
	echo "armed screen buttons are wrong: $(head -1 "$UI_LOG")" >&2
	exit 1
fi
for PRESSES in "B" "X B" "A B"; do
	armed_press "$PRESSES"
	if [ ! -f "$TMP/ARMED" ]; then
		echo "armed screen cancelled the campaign on: $PRESSES" >&2
		exit 1
	fi
done
rm -f "$TMP/ARMED"

echo "== undervolt data tests: ALL PASS =="
