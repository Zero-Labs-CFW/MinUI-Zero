#!/bin/sh
# File Transfer on h700 ships tg5040's aarch64 busybox ftpd and dufs (workspace/tg5040/other). Only tg5040's makefile
# enforces their pins, and `make h700` never runs it, so a stale or altered binary could ship (Codex pre-release
# review 2026-10-09). This checks the same pins from the makefile's own values: dufs by binary hash, busybox by
# the pinned commit, the patch applied and a binary built after that pin. Usage: h700-check-ft-bins.sh <repo>
REPO=${1:?repo}
MK="$REPO/workspace/tg5040/makefile"
O="$REPO/workspace/tg5040/other"
val() { sed -n "s/^$1=//p" "$MK" | head -1; }
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }
fail() { echo "ERROR: $1; run 'make tg5040-frontend' (its early target re-pins it)"; exit 1; }

want=$(val DUFS_BIN_SHA256)
[ -n "$want" ] || fail "no DUFS_BIN_SHA256 in $MK"
[ -f "$O/dufs/dufs" ] || fail "workspace/tg5040/other/dufs/dufs missing"
[ "$(sha "$O/dufs/dufs")" = "$want" ] || fail "dufs does not match its pinned hash"

hash=$(val BUSYBOX_HASH)
[ -n "$hash" ] || fail "no BUSYBOX_HASH in $MK"
[ -f "$O/busybox/busybox" ] || fail "workspace/tg5040/other/busybox/busybox missing"
[ -f "$O/busybox/.minui-zero-$hash" ] || fail "busybox is not at its pinned commit $hash"
[ "$(git -C "$O/busybox" rev-parse HEAD 2>/dev/null)" = "$hash" ] || fail "busybox checkout is not $hash"
p_want=$(grep -E '^[-+]' "$O/patches/busybox-ftpd.patch" | grep -vE '^(\+\+\+|---) ')
p_have=$(git -C "$O/busybox" diff HEAD 2>/dev/null | grep -E '^[-+]' | grep -vE '^(\+\+\+|---) ')
[ "$p_have" = "$p_want" ] || fail "busybox checkout differs from other/patches/busybox-ftpd.patch"
[ "$O/busybox/busybox" -nt "$O/busybox/.minui-zero-$hash" ] || fail "busybox binary is older than its pin"
# the config is a make prerequisite of the binary (by time, as in the makefile); the patch is checked by content above
[ "$O/busybox/busybox" -nt "$O/patches/busybox-ftpd.config" ] || fail "busybox binary is older than busybox-ftpd.config"
echo "File Transfer binaries match their pins (dufs $(val DUFS_VERSION), busybox $hash + patch)"
