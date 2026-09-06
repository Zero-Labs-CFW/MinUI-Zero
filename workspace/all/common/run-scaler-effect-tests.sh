#!/bin/sh
set -eu
cd "$(dirname "$0")"
out=$(mktemp -d "${TMPDIR:-/tmp}/scaler-effect.XXXXXX")
trap 'rm -rf "$out"' EXIT HUP INT TERM
flags=""
case "${1:-plain}" in
  plain) ;;
  asan) flags="-fsanitize=address,undefined -fno-omit-frame-pointer" ;;
  *) echo "usage: $0 [plain|asan]" >&2; exit 2 ;;
esac
${CC:-cc} -std=gnu99 -O2 -g $flags -Itests/scaler -I. \
  scaler.c scaler_effect_test.c -o "$out/test"
"$out/test"

# Test the actual minarch geometry and menu code with framebuffer/SDL stubs. Extract
# complete functions at build time so integration changes cannot leave a stale model.
awk '/^static void selectScaler\(/ {p=1} p {print} p && /^}/ {exit}' \
  ../minarch/minarch.c > "$out/select-scaler.inc"
awk '/^static void Menu_scale\(/ {p=1} p {print} p && /^}/ {exit}' \
  ../minarch/minarch.c > "$out/menu-scale.inc"
awk '/^#define (MIN|MAX|CEIL_DIV)\(/ {print}' defines.h > "$out/geometry-types.inc"
awk '/^[[:space:]]*SCALE_NATIVE,/ {print "enum {"; p=1} p {print} p && /^};/ {exit}' \
  ../minarch/minarch.c >> "$out/geometry-types.inc"
awk '/^[[:space:]]*EFFECT_NONE,/ {print "enum {"; p=1} p {print} p && /^};/ {exit}' \
  api.h >> "$out/geometry-types.inc"
awk '/^typedef struct GFX_Renderer / {p=1} p {print} p && /^} GFX_Renderer;/ {exit}' \
  api.h >> "$out/geometry-types.inc"
for platform in miyoomini h700 control; do
  case "$platform" in
    miyoomini) source=miyoomini; define=-DGOV_PLATFORM_MIYOOMINI ;;
    h700) source=h700; define=-DGOV_PLATFORM_H700 ;;
    control) source=h700; define= ;;
  esac
  awk '/^scaler_t PLAT_getScaler\(/ {p=1} p {print} p && /^}/ {exit}' \
    "../../$source/platform/platform.c" > "$out/platform-scaler.inc"
  ${CC:-cc} -std=gnu99 -O2 -g -Wno-deprecated-declarations $flags $define -Itests/scaler -I. -I"$out" \
    scaler.c scaler_geometry_test.c -o "$out/geometry"
  printf '%s: ' "$platform"
  "$out/geometry"
done

awk '/^static void disp_screen_win\(/ {p=1} p {print} p && /^}/ {exit}' \
  ../../h700/platform/platform.c > "$out/h700-geometry.inc"
awk '/^void PLAT_getGameRect\(/ {p=1} p {print} p && /^}/ {exit}' \
  ../../h700/platform/platform.c >> "$out/h700-geometry.inc"
# Verify the tested canvas dimensions are also what the real DE configuration uses.
grep -Fq 'disp_screen_win(FIXED_WIDTH, FIXED_HEIGHT, &vid.lcfg.info.screen_win)' \
  ../../h700/platform/platform.c
${CC:-cc} -std=gnu99 -O2 -g $flags -I"$out" \
  scaler_h700_geometry_test.c -o "$out/h700-geometry"
"$out/h700-geometry"
