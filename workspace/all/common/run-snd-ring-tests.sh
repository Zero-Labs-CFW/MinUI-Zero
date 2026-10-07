#!/bin/sh
# lock-free audio ring + space wake-up (snd_ring.h, D73): plain, then TSan and ASan where available.
set -e
cd "$(dirname "$0")"
OUT="${TMPDIR:-/tmp}/snd_ring_test"
cc -std=c11 -Wall -Wextra -Werror -O2 snd_ring_test.c -o "$OUT" -lpthread
"$OUT"
if cc -std=c11 -O1 -g snd_ring_test.c -o "$OUT-tsan" -lpthread -fsanitize=thread 2>/dev/null; then
  echo "== TSan =="
  "$OUT-tsan" 300000
else
  echo "== TSan unavailable on this host: skipped =="
fi
if cc -std=c11 -O1 -g snd_ring_test.c -o "$OUT-asan" -lpthread -fsanitize=address 2>/dev/null; then
  echo "== ASan =="
  "$OUT-asan" 300000
else
  echo "== ASan unavailable on this host: skipped =="
fi
