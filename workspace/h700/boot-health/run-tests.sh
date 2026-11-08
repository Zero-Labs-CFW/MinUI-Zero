#!/bin/sh
set -eu

HERE=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/zero-boot-health.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
CC=${CC:-cc}

# Set CFLAGS for an additional sanitizer build; no device or network dependency.
"$CC" -std=c99 -Wall -Wextra -Werror -pedantic ${CFLAGS:-} \
    "$HERE/boot-health.c" "$HERE/boot_health.c" -o "$TMP/boot-health"
"$CC" -std=c99 -Wall -Wextra -Werror -pedantic ${CFLAGS:-} \
    "$HERE/boot_health_test.c" "$HERE/boot_health.c" -o "$TMP/boot-health-test"
"$TMP/boot-health-test" "$TMP"
if "$TMP/boot-health" --bypass 1 >/dev/null 2>&1; then
    echo "boot-health: unknown option accepted" >&2
    exit 1
fi
echo "boot-health: CLI build and host tests passed"
