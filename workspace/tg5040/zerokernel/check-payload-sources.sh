#!/bin/sh
# check-payload-sources.sh: the staged payload (payload/, ignored) must match what is tracked here, not only its own
# payload.sha256 (review 2026-11-19 finding 5). payload.sha256 pins the bytes that were staged; this checks they are
# still the current sources, so a source edit committed without re-running stage-payload.sh fails the build instead
# of shipping the old file under the same VERSION (devices key overlay_current on VERSION only, and would never
# pick up the fix).
#
#   - the payload's copies of rc-stub, S01zero, K01zero, guard and zero-xr829, byte for byte
#   - zerokernel.sh's procd patch table: stage-payload.sh checks it against the stock procd and then pins its sha256
#     in payload.pins; a table edited since then fails here until the payload is staged (and so checked) again
#   - zerokernel.sh's Brick stock recovery md5 (the no-backup undo): regenerated from the payload's
#     recovery-stock-head.bin the way the undo writes it
#   - zerokernel.sh's MODDIR is a directory the payload ships
#
# Usage: sh check-payload-sources.sh             (the makefile, system target)
#        sh check-payload-sources.sh --write-pins (stage-payload.sh, after its procd check passed)
set -u
HERE=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
P="$HERE/payload"
ZK="$HERE/../../../skeleton/SYSTEM/tg5040/bin/zerokernel.sh"
PINS="$HERE/payload.pins"

sha() { { shasum -a 256 2>/dev/null || sha256sum; } | cut -d' ' -f1; }
md5s() { { md5 -q 2>/dev/null || md5sum; } | cut -d' ' -f1; }
procd_table() { sed -n "/^ZK_PROCD=\"/,/^\"\$/p; /^ZK_PROCD_PATCH='/,/^'\$/p" "$ZK"; }

if [ "${1:-}" = --write-pins ]; then
	t=$(procd_table)
	[ -n "$t" ] || { echo "check-payload-sources: no procd table in zerokernel.sh" >&2; exit 1; }
	echo "$(printf '%s\n' "$t" | sha)  zerokernel.sh procd patch table" > "$PINS"
	exit 0
fi

bad=0
fail() { echo "ERROR: $*" >&2; bad=1; }
for pair in "rc-stub root/etc/rc.d/S01zero" "rc-stub root/etc/rc.d/K01zero" "S01zero root/usr/lib/zero/rc/S01zero" \
	"K01zero root/usr/lib/zero/rc/K01zero" "guard root/usr/lib/zero/rc/guard" "zero-xr829 root/usr/lib/zero/modules.d/zero-xr829"; do
	src=${pair%% *}; dst=${pair#* }
	[ -f "$P/$dst" ] || { fail "payload has no $dst (copy of workspace/tg5040/zerokernel/$src)"; continue; }
	[ "$(sha < "$HERE/$src")" = "$(sha < "$P/$dst")" ] \
		|| fail "payload/$dst is not the current workspace/tg5040/zerokernel/$src: re-run stage-payload.sh"
done

pin=; [ -f "$PINS" ] && pin=$(sed -n 's/^\([0-9a-f]\{64\}\)  zerokernel.sh procd patch table$/\1/p' "$PINS")
[ -n "$pin" ] || fail "no procd table pin in payload.pins: re-run stage-payload.sh"
[ -z "$pin" ] || [ "$(procd_table | sha)" = "$pin" ] \
	|| fail "zerokernel.sh's procd patch table changed since stage-payload.sh checked it: re-run stage-payload.sh"

want=$(sed -n 's/.*"Trimui Brick") echo \([0-9a-f]\{32\}\) .*/\1/p' "$ZK")
got=$({ cat "$P/recovery-stock-head.bin"; dd if=/dev/zero bs=512 count=32767 2>/dev/null; } | md5s)
[ -n "$want" ] && [ "$got" = "$want" ] \
	|| fail "zerokernel.sh's Brick stock recovery md5 (${want:-none}) is not what payload/recovery-stock-head.bin regenerates ($got)"

moddir=$(sed -n 's/^MODDIR=\([^ ]*\).*/\1/p' "$ZK")
[ -n "$moddir" ] && [ -d "$P/root$moddir" ] || fail "zerokernel.sh's MODDIR (${moddir:-none}) is not in the payload"

[ "$bad" = 0 ] || exit 1
echo "tg5040 kernel payload: tracked sources and zerokernel.sh pins match"
