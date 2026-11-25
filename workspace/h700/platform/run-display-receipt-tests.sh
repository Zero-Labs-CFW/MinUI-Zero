#!/bin/sh
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
out=$(mktemp -d "${TMPDIR:-/tmp}/h700-receipt.XXXXXX")
trap 'rm -rf "$out"' EXIT HUP INT TERM
for mode in plain sanitized; do
    flags=
    if [ "$mode" = sanitized ]; then flags="-fsanitize=address,undefined -fno-omit-frame-pointer"; fi
    ${CC:-cc} -std=gnu99 -Wall -Wextra -Werror $flags "$here/display_receipt_test.c" -o "$out/test"
    mkdir "$out/$mode"
    "$out/test" "$out/$mode"
done
python3 "$here/../../../tools/test-h700-boot-timing.py"
python3 -B -m unittest discover -s "$here/../../../tools/tests" -p 'test_h700_frame_receipt.py'
python3 -B -m unittest discover -s "$here/../../../tools/tests" -p 'test_h700_present_success.py'
