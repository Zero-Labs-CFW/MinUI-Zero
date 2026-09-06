#!/bin/sh
set -eu
cd "$(dirname "$0")"
src="$PWD"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/minui-recents.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

awk '/^#define INT_ARRAY_MAX / {print} /^typedef struct (Array|Entry|IntArray|Directory|Recent) \{/ {p=1} p {print} p && /^}/ {p=0}' minui.c > "$tmp/recent_types.inc"
awk '/^static (Array\* Array_new|void Array_push|void\* Array_pop|void Array_free|void Entry_free|void Recent_free)\(/ {p=1} p {print} p && /^}/ {p=0}' minui.c > "$tmp/recent_cleanup.inc"
awk '/^static int clearRecents\(/ {p=1} p {print} p && /^}/ {p=0}' minui.c > "$tmp/recent_clear.inc"
awk '/^\t\tif \(show_version\) \{/ {p=1} p && /^\t\tif \(dirty\) \{/ {exit} p {print}' minui.c > "$tmp/recent_input.inc"
test -s "$tmp/recent_input.inc"
cc=${CC:-cc}
for mode in plain asan; do
	flags="-O2"
	if [ "$mode" = asan ]; then flags="-O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer"; fi
	$cc -std=gnu99 $flags -Wall -Wextra -I"$tmp" "$src/recent_test.c" -o "$tmp/test"
	mkdir "$tmp/$mode"
	(cd "$tmp/$mode" && ../test)
done

if command -v pkg-config >/dev/null && pkg-config --exists sdl2 SDL2_ttf; then
	awk '/^#define (BUTTON_SIZE|BUTTON_MARGIN|FONT_SMALL|FONT_LARGE|FONT_TINY) / {print} /^#define PILL_SIZE / {print}' ../common/defines.h > "$tmp/recent_layout.inc"
	awk '/^int GFX_(getButtonWidth|blitButtonGroup)\(/ {p=1} p {print} p && /^}/ {p=0}' ../common/api.c >> "$tmp/recent_layout.inc"
	awk '/^static int recentFooterCompact\(/ {p=1} p {print} p && /^}/ {p=0}' minui.c >> "$tmp/recent_layout.inc"
	$cc -std=gnu99 -O2 -I"$tmp" $(pkg-config --cflags sdl2 SDL2_ttf) "$src/recent_layout_test.c" \
		-o "$tmp/layout" $(pkg-config --libs sdl2 SDL2_ttf)
	"$tmp/layout" ../../../skeleton/SYSTEM/res/BPreplayBold-unhinted.otf
else
	echo "SKIP recent footer layout: host SDL2/SDL2_ttf development libraries not installed"
fi
