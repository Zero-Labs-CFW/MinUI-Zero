#!/bin/sh
# Lean libSDL2_ttf for the H700 menu (boot speed, 2026-11-05). SDL_ttf 2.22.0, the version muOS ships, built with its
# bundled FreeType linked in and HarfBuzz off: the menu then no longer loads freetype + harfbuzz + glib + pcre2 + brotli
# + bz2 (~3.9 MB of cold card reads at every boot, Plus, block_dump) for plain-text rendering. HarfBuzz only shapes
# complex scripts (Arabic, Indic, Thai), which MinUI's font does not cover anyway. The card payload's lib folder is
# first on the menu's LD_LIBRARY_PATH, so this one wins over muOS's.
#   sh workspace/h700/sdl2_ttf/build.sh <cache dir>      -> <cache dir>/libSDL2_ttf-2.0.so.0
set -e
CACHE=$1
TAR=SDL2_ttf-2.22.0.tar.gz; SUM=d48cbd1ce475b9e178206bf3b72d56b66d84d44f64ac05803328396234d67723
mkdir -p "$CACHE"
if [ ! -f "$CACHE/$TAR" ]; then
	curl -fsSL "https://github.com/libsdl-org/SDL_ttf/releases/download/release-2.22.0/$TAR" -o "$CACHE/$TAR.part"
	mv "$CACHE/$TAR.part" "$CACHE/$TAR"
fi
[ "$(shasum -a 256 "$CACHE/$TAR" | cut -d' ' -f1)" = "$SUM" ] || { echo "ERROR: $TAR checksum"; exit 1; }
docker run --rm --platform linux/amd64 -v "$CACHE:/w" tg5040-toolchain bash -ec '
cd /tmp && tar xzf /w/'"$TAR"' && cd SDL2_ttf-2.22.0
CC=/opt/aarch64-linux-gnu/bin/aarch64-linux-gnu-gcc
SYS=$($CC -print-sysroot)
./configure --host=aarch64-linux-gnu CC="$CC" CFLAGS="-O2" --enable-freetype-builtin --disable-harfbuzz \
	--disable-static --with-sdl-prefix=$SYS/usr >/tmp/cfg.log 2>&1 || { tail -30 /tmp/cfg.log; exit 1; }
make -j8 >/tmp/make.log 2>&1 || { tail -30 /tmp/make.log; exit 1; }
L=$(ls .libs/libSDL2_ttf-2.0.so.0.* | head -1)
${CC%gcc}strip --strip-unneeded "$L"
cp "$L" /w/libSDL2_ttf-2.0.so.0.part
# the whole point: nothing but libc, libm and SDL2; checked BEFORE it replaces the cache, which only ever holds a good one
if ${CC%gcc}readelf -d /w/libSDL2_ttf-2.0.so.0.part | grep NEEDED | grep -v -q -E "\[(libc|libm|libSDL2-2\.0)\.so"; then
	rm -f /w/libSDL2_ttf-2.0.so.0.part; echo "ERROR: unexpected dependency"; exit 1
fi
mv /w/libSDL2_ttf-2.0.so.0.part /w/libSDL2_ttf-2.0.so.0   # atomic: no half copy in the cache
'
echo "built $CACHE/libSDL2_ttf-2.0.so.0"
