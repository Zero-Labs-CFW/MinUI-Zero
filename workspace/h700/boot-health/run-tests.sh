#!/bin/sh
set -eu

HERE=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/zero-boot-health.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
CC=${CC:-cc}
BUILD_ID=000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f

# Set CFLAGS for an additional sanitizer build; no device or network dependency.
"$CC" -std=c99 -Wall -Wextra -Werror -pedantic "-DZERO_HEALTH_BUILD_ID=\"$BUILD_ID\"" ${CFLAGS:-} \
    "$HERE/boot-health.c" "$HERE/boot_health.c" -o "$TMP/boot-health"
"$CC" -std=c99 -Wall -Wextra -Werror -pedantic "-DZERO_HEALTH_BUILD_ID=\"$BUILD_ID\"" ${CFLAGS:-} \
    "$HERE/boot_health_test.c" "$HERE/boot_health.c" -o "$TMP/boot-health-test"
"$TMP/boot-health-test" "$TMP"
[ "$("$TMP/boot-health" --contract)" = zero-stage2-health-v1 ]
[ "$("$TMP/boot-health" --build-id)" = "$BUILD_ID" ]
if "$TMP/boot-health" --bypass 1 >/dev/null 2>&1; then
    echo "boot-health: unknown option accepted" >&2
    exit 1
fi
echo "boot-health: CLI build and host tests passed"
