#!/bin/sh
# File Transfer on h700 ships tg5040's aarch64 busybox ftpd and dufs (workspace/tg5040/other). Only tg5040's makefile
# enforces their pins, and `make h700` never runs it, so a stale or altered binary could ship (Codex pre-release
# review 2026-10-09). This checks the same pins from the makefile's own values: dufs by binary hash, busybox by
# the pinned commit, the patch applied and the build stamp that ties the binary to them. Usage: h700-check-ft-bins.sh <repo>
REPO=${1:?repo}
MK="$REPO/workspace/tg5040/makefile"
O="$REPO/workspace/tg5040/other"
val() { sed -n "s/^$1=//p" "$MK" | head -1; }
shs() { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi | cut -d' ' -f1; }
sha() { shs < "$1"; }
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
# the binary itself, by the stamp the makefile writes after a verified build (stamp_ok: line 1 = sha256 of the binary,
# line 2 = of the patch + config it was built from). File dates cannot catch an old unpatched binary copied in later,
# whose ftpd would reject File Transfer's one-time login (Codex review 2026-10-10)
st="$O/busybox/.minui-zero-build"
[ -f "$st" ] || fail "busybox has no build stamp"
[ "$(sha "$O/busybox/busybox")" = "$(sed -n 1p "$st")" ] || fail "busybox binary does not match its build stamp"
[ "$(cat "$O/patches/busybox-ftpd.patch" "$O/patches/busybox-ftpd.config" | shs)" = "$(sed -n 2p "$st")" ] || \
	fail "busybox was built from a different patch or config"
[ -z "$(git -C "$O/busybox" status --porcelain --untracked-files=all | grep '^??' | grep -v '\.minui-zero-')" ] || \
	fail "busybox checkout has untracked files"
echo "File Transfer binaries match their pins (dufs $(val DUFS_VERSION), busybox $hash + patch)"
