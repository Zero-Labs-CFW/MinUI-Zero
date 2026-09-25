#!/bin/sh
# Build MinUI Zero h700 by STRIPPING muOS (Dan's call, 2026-08-06: "why reinvent the wheel").
#
# Base = muOS's proven rootfs (from the local dump): working wifi, ssh, udev module autoload,
# display init, power, every library, the correct kernel + modules. We DELETE the frontend/apps/
# theme bloat and swap the frontend-launch for MinUI. Everything below the UI stays muOS's.
#
# This replaces the from-scratch approach (tools/build-h700-image.sh), which failed by rebuilding
# a whole userland one missing library at a time. See .notes/2026-08-06-h700-architecture/.
#
# CLEAN-CLONE INPUTS (gitignored, under .notes/2026-08-05-h700-image/ of the checkout being built; the
# v1.8.0 release clone lacked them one at a time, 2026-09-22): muos-p5.img (8 GB muOS dump, a REAL file or a
# hard link, never a symlink out of the docker mount), parts/ (p2-p4 + raw-36mb chain), parts-<device>/ and
# device-<device>/ overlays. A release build also needs H700_VERSION=vX.Y.Z until the tag exists.
# Pipeline (all offline, no device): debugfs rdump the muOS rootfs -> strip the bloat list ->
# swap FRONTEND->minui in startup.sh + drop our launcher -> mke2fs -d a lean p5 -> assemble with
# the verbatim boot chain + our FAT ROMS payload.
set -e

REPO="$(cd "$(dirname "$0")/.." && pwd)"
ASSETS="${H700_ASSETS:-$REPO/.notes/2026-08-05-h700-image}"
OUT_DIR="$ASSETS/out"
MUOS_ROOTFS="$ASSETS/muos-p5.img"
MT=/opt/homebrew/bin

# BUILD MODE, dev (default) vs release. The difference is exactly the dev-loop conveniences, and
# each of them is actively harmful in a stranger's hands:
#   authorized_keys, a dev image bakes in the builder's ssh public key. Shipping that would
#                     authorize ONE person's key on every user's device. A release ships none, and
#                     the frontend installs a key from the card root instead (user's own, opt-in).
#   devmode.txt, arms stay-awake: no autosleep, no idle power-off. On a release that is a
#                     device that never sleeps, i.e. the exact opposite of this fork's thesis.
# Release also stamps the version from the git tag rather than today's date.
MODE="${H700_MODE:-dev}"
case "$MODE" in
	dev|release) ;;
	*) echo "ERROR: H700_MODE must be 'dev' or 'release' (got '$MODE')"; exit 1 ;;
esac
if [ "$MODE" = release ]; then
	# H700_VERSION wins; otherwise the nearest reachable tag, but it MUST look like one of ours
	# (vN.N.N). This branch's nearest tag is upstream MinUI's `v20231113b`, so an unchecked
	# `git describe` would have quietly stamped a release with an upstream version number.
	VERSION="${H700_VERSION:-$(cd "$REPO" && git describe --tags --abbrev=0 2>/dev/null || true)}"
	case "$VERSION" in
		v[0-9]*.[0-9]*.[0-9]*) ;;
		"") echo "ERROR: release build found no tag, set H700_VERSION=vX.Y.Z"; exit 1 ;;
		*)  echo "ERROR: '$VERSION' is not a MinUI Zero release tag (expected vX.Y.Z)."
		    echo "       The nearest reachable tag on this branch is upstream MinUI's."
		    echo "       Tag the release, or pass H700_VERSION=vX.Y.Z."; exit 1 ;;
	esac
	IMG="$OUT_DIR/MinUI-Zero-h700-$VERSION.img"
else
	VERSION="dev-$(date +%Y%m%d)"
	IMG="$OUT_DIR/MinUI-Zero-h700-stripped-$(date +%Y%m%d).img"
fi
# TARGET DEVICE. muOS keeps every board in one tree and selects ONE at image-build time, nothing
# installs a device package at runtime, so a different handheld means a different IMAGE, not a
# runtime switch. Default is the Plus (the donor we dumped and the only device verified end to end).
#
#   rg35xx-plus  uses the donor boot chain as-is
#   rg35xx-h     substitutes that board's boot_package (u-boot + device tree) into the chain and
#                overlays its /opt/muos/device, which is what makes its analog sticks exist at all:
#                the H tree enables a GPADC + analog mux and adds keyL3/keyR3, none of it in the Plus.
DEVICE="${H700_DEVICE:-rg35xx-plus}"
DEVICE_DIR="$ASSETS/device-$DEVICE"
RAW36="$ASSETS/parts/raw-36mb.img.gz"          # the Plus chain, our proven baseline
BUILT_RAW=""                                    # set when we synthesize a chain for another board
if [ "$DEVICE" != "rg35xx-plus" ]; then
	[ -d "$DEVICE_DIR" ] || { echo "ERROR: no device tree at $DEVICE_DIR, run: python3 tools/h700-image/fetch-device.py $DEVICE $DEVICE_DIR"; exit 1; }
	echo "== target device: $DEVICE (building a boot chain from its muOS package) =="
	mkdir -p "$OUT_DIR"
	gunzip -c "$RAW36" > "$OUT_DIR/base-raw36.img"
	python3 "$REPO/tools/h700-image/bootchain.py" "$OUT_DIR/base-raw36.img" \
		"$DEVICE_DIR/package/boot_package.fex" "$OUT_DIR/raw36-$DEVICE.img" || exit 1
	BUILT_RAW="$OUT_DIR/raw36-$DEVICE.img"
	rm -f "$OUT_DIR/base-raw36.img"
	# FAIL CLOSED on the kernel: every board names its kernel explicitly in parts-<device>/, never via the
	# silent part() fallback. TODAY EVERY BOARD USES THE PLUS KERNEL (copy parts/p4-kernel.img.gz in):
	# the boards' own muOS kernels hang at the boot logo on our Plus-derived rootfs (RG35XX H, 2026-09-23),
	# and the Plus kernel drives every board's panel (all use fog_fj035fhd05_v1). It lacks the per-board
	# extras: analog sticks (amux/sunxi-gpadc: H, Pro, 40XX), the SP lid (hallkey), the 40XX LED chip
	# power (mcu_pwr) and possibly 40XX rumble (pwm3). Getting those back means solving the own-kernel
	# hang (audit 2026-09-25, .notes/2026-09-24-nextui-h700-research/).
	[ -f "$ASSETS/parts-$DEVICE/p4-kernel.img.gz" ] || {
		echo "ERROR: $DEVICE needs its own kernel at $ASSETS/parts-$DEVICE/p4-kernel.img.gz"
		echo "       (extract p4 from that board muOS image; the fallback would ship the Plus kernel)"
		exit 1; }
fi

# Stale-artifact guard: remove any previous image under this exact name NOW, not at assembly time.
# Otherwise a build that fails partway (rootfs extract, device overlay, boot-chain synthesis) leaves
# an older same-name .img and .xz sitting there looking current, and a later upload publishes stale
# code from a build that never succeeded.
rm -f "$IMG" "$IMG.xz"

IMG="${IMG%.img}-$DEVICE.img"   # every image names its board; they are NOT interchangeable

echo "== build mode: $MODE (version $VERSION) =="

# Refresh the dev ssh key BEFORE the rootfs build consumes it (the copy used to sit near the end of
# the script, so every run baked in the PREVIOUS run's key). Release mode removes it outright so a
# stale file from an earlier dev build cannot leak into a shipped image.
rm -f "$ASSETS/authorized_keys"
if [ "$MODE" = dev ]; then
	cp "$HOME/.ssh/tg5040_dev.pub" "$ASSETS/authorized_keys" 2>/dev/null || true
fi

# geometry (sectors) — p1-p4 verbatim muOS offsets; p5 sized to the STRIPPED rootfs
P5_FIRST=319488
P5_SECTORS=2097152      # 1GB rootfs (stripped muOS lands ~500-900MB; headroom for now)
P5_LAST=$((P5_FIRST + P5_SECTORS - 1))
P6_FIRST=$((P5_LAST + 1))
P6_SECTORS=524288       # 256MB ROMS (FAT32)
P6_LAST=$((P6_FIRST + P6_SECTORS - 1))
TOTAL=$((P6_LAST + 40))

[ -f "$MUOS_ROOTFS" ] || { echo "ERROR: muOS rootfs dump not at $MUOS_ROOTFS"; exit 1; }
[ -f "$REPO/workspace/all/minui/build/h700/minui.elf" ] || { echo "ERROR: run 'make h700-build' first"; exit 1; }
# FRESHNESS, not just existence. Every flashed image carried a STALE minui.elf for a day because
# this check passed on a binary older than the sources: the power-off logic had been fixed in
# api.c, `make h700-build` said nothing to do, and the image builder happily shipped the old
# binary while everyone debugged the device (2026-08-27). A build artifact older than any of its
# shared or platform sources fails the build. Same class of gate as check-cores/check-payload:
# the artifact must be checked against its own claim, and "exists" is not "current".
_newest_src=$(find "$REPO/workspace/all/common" "$REPO/workspace/all/minui" "$REPO/workspace/all/minarch" 	"$REPO/workspace/h700" -name "*.c" -o -name "*.h" 2>/dev/null | xargs stat -f "%m" 2>/dev/null | sort -n | tail -1)
_elf_time=$(stat -f "%m" "$REPO/workspace/all/minui/build/h700/minui.elf" 2>/dev/null || echo 0)
if [ "${_newest_src:-0}" -gt "${_elf_time:-0}" ]; then
	echo "ERROR: minui.elf is OLDER than the sources; run 'make h700-build' before building an image."
	echo "       (a stale binary here ships silently and costs a device-debugging session)"
	exit 1
fi
echo "  frontend binaries: current"

mkdir -p "$OUT_DIR"

# ---- p5 -----------------------------------------------------------------------------------------
# H700_P5 lets an externally built rootfs stand in for the denylist-stripped one, so the allowlist
# build (tools/h700-rootfs/build-rootfs.sh) can be flashed without duplicating the boot chain, GPT
# and FAT payload work that lives below. Everything after this point is identical either way.
if [ -n "$H700_P5" ]; then
	[ -f "$H700_P5" ] || { echo "ERROR: H700_P5=$H700_P5 does not exist"; exit 1; }
	# It must fit the slot, or dd would silently write past p5 and corrupt p6.
	_p5_bytes=$(stat -f%z "$H700_P5" 2>/dev/null || stat -c%s "$H700_P5" 2>/dev/null || echo 0)
	_slot_bytes=$((P5_SECTORS * 512))
	if [ "$_p5_bytes" -gt "$_slot_bytes" ]; then
		echo "ERROR: $H700_P5 is $_p5_bytes bytes but the p5 slot is only $_slot_bytes"
		exit 1
	fi
	echo "== using externally built p5: $H700_P5 ($((_p5_bytes / 1048576)) MB into a $((_slot_bytes / 1048576)) MB slot) =="
	cp "$H700_P5" "$OUT_DIR/p5.img"
else

# ---- p5: extract muOS rootfs, strip, inject our launcher, rebuild (all in the container) ----
echo "== extracting + stripping muOS rootfs (this takes a few minutes) =="
cp "$REPO/tools/h700-strip/minui-frontend.sh" "$ASSETS/minui-frontend.sh"
cp "$REPO/tools/h700-strip/expand-roms.sh" "$ASSETS/expand-roms.sh"
# First-boot "Installing MinUI Zero..." frame for expand-roms.sh (raw fb page, panel-sized). Best
# effort: no PIL on the host means no splash, never a failed build.
rm -f "$ASSETS/installing.raw"
python3 "$REPO/tools/h700-strip/make-splash.py" "$REPO/workspace/tg5040/install/installing.png" "$ASSETS/installing.raw" 640 480 \
	|| echo "WARN: installing splash not rendered (python3 PIL missing); first boot shows the boot logo only"
docker run --rm --platform linux/amd64 -v "$ASSETS:/a" -e P5_KB=$((P5_SECTORS / 2)) -e DEVICE="$DEVICE" -e MODE="$MODE" tg5040-toolchain /bin/bash -c '
set -e
R=/work/root
rm -rf "$R"; mkdir -p "$R"
echo "  rdump (2.6GB, be patient)..."
debugfs -R "rdump / $R" /a/muos-p5.img 2>/dev/null
# fail HERE, not 140 lines later at a sed on startup.sh: an empty rdump (the dump was a symlink pointing
# outside the docker mount, release clone 2026-09-22) otherwise reads as a stripped-but-odd rootfs
[ -f "$R/opt/muos/script/system/startup.sh" ] || { echo "ERROR: rdump produced no rootfs (is muos-p5.img a real file inside the mount, not a symlink out of it?)"; exit 1; }

echo "  stripping bloat..."
# frontend UI + its 1.2GB of theme/asset data (we replace the UI with minui)
rm -rf "$R/opt/muos/share" "$R/opt/muos/frontend" "$R/opt/muos/bin" "$R/opt/muos/kiosk"
# heavyweight extras nothing in our boot needs
rm -rf "$R/opt/java" "$R/opt/zulu" "$R/opt/sftpgo" "$R/opt/fish" "$R/opt/micro"
rm -f  "$R/usr/bin/retroarch" "$R/usr/lib/libavcodec."* "$R/usr/lib/libavformat."* "$R/usr/lib/libavfilter."* "$R/usr/lib/libavdevice."*
rm -rf "$R/usr/lib/python3.11" "$R/usr/bin/python3."* "$R/usr/lib/libpython3."*   # muOS scripts are POSIX sh, not python
# Unused libraries (VERIFIED on-device 2026-08-06: minui+minarch launch cleanly without them,
# linker resolves every dependency): GPU (we render via the DE layer, no GL), ICU unicode data
# (was for ImageMagick/heavy apps), ImageMagick (muOS theme rendering), and the EasyRPG game
# engine libs. ~87MB.
# KEEP libmali.so (42.5MB). MinUI never touches it: we present through the DE layer and SDL is
# used only for input, which is why removing it looked free. But /usr/lib holds libEGL.so.1,
# libGLESv2.so and friends as SYMLINKS TO IT, and this SDL2 build offers exactly one video
# driver: "mali". Deleting the target left those symlinks dangling, so every third-party SDL
# app segfaulted the moment it tried to open a window. The Files tool (DinguxCommander) is how
# we found it (rc=139, 2026-08-10); every community tool pak and standalone emulator would hit
# the same wall. It is dormant disk space, not runtime weight: nothing loads it unless an app
# asks for it, so it costs no power, memory or boot time, which is what the thesis is about.
rm -f "$R/usr/lib/libicudata.so."* "$R/usr/lib/libicui18n.so."* "$R/usr/lib/libicuuc.so."*
rm -f "$R/usr/lib/libMagickCore-"* "$R/usr/lib/libMagickWand-"* "$R/usr/bin/magick"* "$R/usr/bin/convert" 2>/dev/null || true
rm -f "$R/usr/lib/libzmusic.so."* "$R/usr/lib/liblcf.so."*
# Audio daemon (9.5MB): pipewire/wireplumber cannot autolaunch a D-Bus session bus on this headless
# rootfs (no X11/DISPLAY) so they never start, and stripping /opt/muos/share below removes their
# config anyway. MinUI Zero routes ALSA straight to the codec instead (asound.conf, added below).
# Only the pipewire tools themselves link libpipewire, and SDL uses the alsa driver — VERIFIED safe.
rm -rf "$R/usr/bin/pipewire"* "$R/usr/bin/wireplumber" "$R/usr/bin/pw-"* \
       "$R/usr/lib/libpipewire-0.3.so."* "$R/usr/lib/libwireplumber-0.4.so."* \
       "$R/usr/lib/spa-0.2" "$R/usr/lib/pipewire-0.3" "$R/usr/lib/wireplumber-0.4" \
       "$R/usr/lib/alsa-lib/libasound_module_pcm_pipewire.so" 2>/dev/null || true
# AGGRESSIVE LEAN (2026-08-08 audit): the muOS base carries a whole 32-bit userland + a full app
# toolkit we never run. VERIFIED offline: arch-scanned EVERY retained ELF (all aarch64, ZERO 32-bit)
# and grepped the retained boot scripts (no refs to anything below). Takes the rootfs 669MB -> ~230MB.
# 281MB: the orphaned 32-bit (armhf) compat tree — muOS ships it for 32-bit RetroArch cores we omit.
rm -rf "$R/usr/lib32" "$R/lib32" "$R/lib/ld-linux-armhf.so.3" 2>/dev/null || true
# ~120MB of assets nothing on our boot/wifi/audio/display/minui path uses:
# (2>/dev/null || true on each: a few vim test files carry the immutable attr and EPERM on rm would
#  otherwise abort the whole build under `set -e`; the tiny remnant is harmless.)
rm -rf "$R/usr/share/fonts/truetype/noto" 2>/dev/null || true   # 63MB CJK fonts (minui ships its own font)
rm -rf "$R/usr/share/soundfonts" 2>/dev/null || true            # 31MB MIDI soundfont
rm -rf "$R/usr/share/vim" "$R/usr/bin/vim" 2>/dev/null || true  # 18MB editor
rm -f  "$R/usr/share/misc/magic.mgc" 2>/dev/null || true        # 8MB file(1) magic db
# dev/util binaries + their app-only libs (none on the boot path; grep-verified):
rm -f "$R/usr/bin/btop" "$R/usr/bin/htop" "$R/usr/bin/dust" "$R/usr/bin/mpv" "$R/usr/bin/7zr" \
      "$R/usr/bin/ld" "$R/usr/bin/ld.bfd" "$R/usr/bin/as" "$R/usr/bin/readelf" "$R/usr/bin/objdump" \
      "$R/usr/bin/bsdunzip" "$R/usr/bin/get_disto" \
      "$R/usr/bin/img2webp" "$R/usr/bin/cwebp" "$R/usr/bin/dwebp" "$R/usr/bin/gif2webp" "$R/usr/bin/webpmux" \
      "$R/usr/bin/webpinfo" "$R/usr/bin/webp_quality" "$R/usr/bin/vwebp" "$R/usr/bin/anim_dump" "$R/usr/bin/anim_diff" 2>/dev/null || true
rm -f "$R/usr/lib/libmpv.so."* "$R/usr/lib/libtcl8.6.so."* "$R/usr/lib/libvpx.so."* \
      "$R/usr/lib/libjanet.so."* "$R/usr/lib/libzmusiclite.so."* 2>/dev/null || true
rm -rf "$R/usr/share/tcltk" 2>/dev/null || true
# Orphaned 64-bit app libraries (dependency-closure analysis 2026-08-08: seeded with all 458
# retained binaries + our minui/minarch/cores; these are referenced by NONE — leftovers from the
# muOS app suite). ~20MB. Names are explicit for the SDL families so the SDL2 core/image/ttf we use
# survive; we also KEEP the dlopen-prone glibc name-resolution libs (nss/resolv/nsl), the image
# codecs SDL2_image may dlopen (jpeg/tiff/webp), and libsamplerate/libopenal/libarchive.
rm -f "$R/usr/lib/libboost_"* 2>/dev/null || true
rm -f "$R/usr/lib/libSDL-1.2.so."* "$R/usr/lib/libSDL_mixer-1.2.so."* "$R/usr/lib/libSDL_image-1.2.so."* "$R/usr/lib/libSDL_gfx.so."* "$R/usr/lib/libSDL_net-1.2.so."* "$R/usr/lib/libSDL_ttf-2.0.so."* 2>/dev/null || true
rm -f "$R/usr/lib/libSDL2_mixer-2.0.so."* "$R/usr/lib/libSDL2_net-2.0.so."* "$R/usr/lib/libSDL2_gfx-1.0.so."* 2>/dev/null || true
rm -f "$R/usr/lib/libpulse"* "$R/usr/lib/libasyncns.so."* 2>/dev/null || true
rm -f "$R/usr/lib/libgnutls.so."* "$R/usr/lib/libp11-kit.so."* "$R/usr/lib/libtasn1.so."* "$R/usr/lib/libidn2.so."* "$R/usr/lib/libgmp.so."* 2>/dev/null || true
rm -f "$R/usr/lib/libdrm_intel.so."* "$R/usr/lib/libdrm_radeon.so."* "$R/usr/lib/libdrm_nouveau.so."* "$R/usr/lib/libdrm_freedreno.so."* 2>/dev/null || true
rm -f "$R/usr/lib/libtheora"* "$R/usr/lib/libFLAC"* "$R/usr/lib/libfaad"* "$R/usr/lib/libass.so."* "$R/usr/lib/libWildMidi.so."* "$R/usr/lib/libxmp.so."* "$R/usr/lib/libsidplay2.so."* "$R/usr/lib/libresid"* "$R/usr/lib/libsidutils.so."* "$R/usr/lib/libhardsid"* "$R/usr/lib/libsbc.so."* "$R/usr/lib/libportmidi.so."* 2>/dev/null || true
rm -f "$R/usr/lib/libmoonlight-common.so."* "$R/usr/lib/libgamestream.so."* "$R/usr/lib/libenet.so."* "$R/usr/lib/libcec.so."* "$R/usr/lib/libcapsimage.so."* "$R/usr/lib/libm3g.so" "$R/usr/lib/libjq.so."* 2>/dev/null || true
rm -f "$R/usr/lib/libopcodes-"* "$R/usr/lib/libctf"* "$R/usr/lib/libdw-"* "$R/usr/lib/libelf-"* "$R/usr/lib/libasm-"* 2>/dev/null || true
rm -f "$R/usr/lib/libevent"* "$R/usr/lib/libwrap.so."* "$R/usr/lib/libwpa_client.so" "$R/usr/lib/libnghttp2.so."* "$R/usr/lib/libfmt.so."* "$R/usr/lib/libatopology.so."* "$R/usr/lib/libnl-xfrm-3.so."* "$R/usr/lib/libapparmor.so."* "$R/usr/lib/libbluetooth.so."* "$R/usr/lib/libserial"* "$R/usr/lib/libusb-1.0.so."* "$R/usr/lib/libparted-fs-resize.so."* 2>/dev/null || true
# Leftover app-tool BINARIES + their libs (ffmpeg/flac/lame/ogg encoders, avahi mDNS, expect, the
# icu/lcf/pipewire tools). Several were ALREADY broken by the base strip; the orphaned-lib cut above
# finished the rest. None are on the boot/wifi/audio/display/minui path. Removing the binaries too
# clears the dangling deps and trims a bit more.
rm -f "$R/usr/bin/ffmpeg" "$R/usr/bin/ffplay" "$R/usr/bin/ffprobe" \
      "$R/usr/bin/flac" "$R/usr/bin/metaflac" "$R/usr/bin/lame" "$R/usr/bin/ogg123" "$R/usr/bin/oggenc" "$R/usr/bin/opusenc" "$R/usr/bin/playsound" "$R/usr/bin/playsound_simple" \
      "$R/usr/bin/avahi-"* "$R/usr/bin/expect" "$R/usr/bin/icuexportdata" "$R/usr/bin/pkgdata" "$R/usr/bin/lcf2xml" "$R/usr/bin/lcfstrings" "$R/usr/bin/wpctl" "$R/usr/bin/wpexec" 2>/dev/null || true
rm -f "$R/usr/lib/libSDL_sound-1.0.so."* "$R/usr/lib/libsndfile.so."* "$R/usr/lib/libpostproc.so."* "$R/usr/lib/libswresample.so."* "$R/usr/lib/libswscale.so."* "$R/usr/lib/libexslt.so."* "$R/usr/lib/libxslt.so."* "$R/usr/lib/libavahi-"* 2>/dev/null || true
# openssh (32MB): we ship dropbearmulti instead (~250KB aarch64, launched by the frontend) — the
# same ssh path the Smart Pro uses. And /etc/udev/hwdb.bin (9.3MB): udev autoloads modules by
# MODALIAS (not hwdb) and h700 input is raw evdev, so the hardware database has no consumer here.
rm -rf "$R/opt/openssh" 2>/dev/null || true
rm -f "$R/etc/udev/hwdb.bin" 2>/dev/null || true

# ---- Deeper lean pass (2026-08-08): drop libs/tools a readelf NEEDED-closure proves have no live
# ---- consumer, trim single-language/single-timezone data, and strip kernel-module debug symbols.
# ---- KEEP note: text rendering is load-bearing on libSDL2_ttf -> libharfbuzz -> libglib, so ALL of
# ---- those (and libfreetype) stay. Everything removed below was verified consumer-free.
# Tier 3 - dependency-verified orphans + their tool-only consumers (X11/cairo island, sqlite,
# samplerate/openal/archive, harfbuzz-subset, xml2, the GLib CLI tools, dead fluidsynth/minimodem):
rm -f "$R/usr/lib/libX11.so."* "$R/usr/lib/libXext.so."* "$R/usr/lib/libXrender.so."* \
      "$R/usr/lib/libcairo.so."* "$R/usr/lib/libpixman-1.so."* "$R/usr/bin/modetest" \
      "$R/usr/lib/libsqlite3.so."* "$R/usr/bin/sqlite3" \
      "$R/usr/lib/libsamplerate.so."* "$R/usr/lib/libopenal.so."* "$R/usr/lib/libarchive.so."* \
      "$R/usr/lib/libharfbuzz-subset.so."* "$R/usr/bin/hb-info" "$R/usr/bin/hb-shape" \
      "$R/usr/bin/hb-subset" "$R/usr/bin/hb-ot-shape-closure" \
      "$R/usr/lib/libxml2.so."* "$R/usr/bin/xml" "$R/usr/bin/xmlcatalog" "$R/usr/bin/xmllint" \
      "$R/usr/lib/libMagick++"* \
      "$R/usr/bin/gio" "$R/usr/bin/gsettings" "$R/usr/bin/gdbus" "$R/usr/bin/gresource" \
      "$R/usr/bin/gapplication" "$R/usr/bin/gio-querymodules" "$R/usr/bin/dbus-binding-tool" \
      "$R/usr/bin/fluidsynth" "$R/usr/lib/libfluidsynth.so."* \
      "$R/usr/lib/libicu"*.so* "$R/usr/lib/libharfbuzz-icu.so."* \
      "$R/usr/bin/minimodem" "$R/usr/bin/spa-resample" 2>/dev/null || true
# Dead ALSA pipewire routing plugins (we route ALSA direct to hw via asound.conf, never via pipewire):
find "$R/usr/lib" -name "libasound_module_*pipewire*" -delete 2>/dev/null || true
# Tier 1 - single-timezone (drop posix/ dup + right/ leap-second trees), single-language (keep C.*):
rm -rf "$R/usr/share/zoneinfo/posix" "$R/usr/share/zoneinfo/right" 2>/dev/null || true
find "$R/usr/lib/locale" -mindepth 1 -maxdepth 1 ! -name "C.*" -exec rm -rf {} + 2>/dev/null || true
rm -f "$R/usr/lib/locale/locale-archive" 2>/dev/null || true
# gconv: keep the UTF/ASCII/Latin-1 converters + the module map; drop exotic charset .so files.
if [ -d "$R/usr/lib/gconv" ]; then
  find "$R/usr/lib/gconv" -maxdepth 1 -name "*.so" \
    ! -name "UTF-16.so" ! -name "UTF-32.so" ! -name "UTF-7.so" ! -name "UNICODE.so" \
    ! -name "ANSI_X3.4.so" ! -name "ISO8859-1.so" ! -name "ISO8859-15.so" ! -name "CP1252.so" \
    -delete 2>/dev/null || true
fi
# Tier 2 - strip debug symbols from the (vendor-unstripped) kernel modules. MUST use the aarch64
# strip: the host x86 strip cannot read aarch64 .ko. This alone reclaims ~23MB (single modules go
# from ~17MB to ~0.7MB), so it dwarfs everything else in this pass.
_msz=$(du -sh "$R/lib/modules" 2>/dev/null | cut -f1)
KOSTRIP=$(command -v aarch64-linux-gnu-strip 2>/dev/null || echo /opt/aarch64-linux-gnu/bin/aarch64-linux-gnu-strip)
find "$R/lib/modules" -name "*.ko" -exec "$KOSTRIP" --strip-debug {} + 2>/dev/null || true
echo "  kernel modules: $_msz -> $(du -sh "$R/lib/modules" 2>/dev/null | cut -f1) after .ko debug-strip"
# KEEP: /opt/muos/script (init + network.sh + halt.sh + func.sh), /opt/muos/device + config,
#       udev, wifi stack, dropbearmulti (ssh), SDL, kernel modules, alsa-utils (amixer/alsactl),
#       gl4es/libopenal/libsamplerate/embiggen-disk (possible SDL/runtime deps — not worth the risk)

# TARGET-DEVICE OVERLAY. The rdumped rootfs carries the DONOR board (rg35xx-plus) in
# /opt/muos/device, and every muOS boot script reads its identity and hardware paths from there via
# GET_VAR, board/name, board/stick, board/rtc_wake, screen geometry, the alsa baseline. Shipping it
# unchanged on another handheld means the OS honestly believes it is a Plus. Replace it wholesale.
if [ -n "$DEVICE" ] && [ "$DEVICE" != "rg35xx-plus" ] && [ -d "/a/device-$DEVICE" ]; then
	rm -rf "$R/opt/muos/device"
	mkdir -p "$R/opt/muos/device"
	cp -R "/a/device-$DEVICE/." "$R/opt/muos/device/"
	echo "  /opt/muos/device replaced with $DEVICE ($(cat "$R/opt/muos/device/config/board/name" 2>/dev/null))"
fi

echo "  swapping FRONTEND -> minui in startup.sh..."
SU="$R/opt/muos/script/system/startup.sh"
# replace the frontend launch with our loop; skip the hotkey daemon (minui reads input directly)
sed -i "s|^FRONTEND start|sh /opt/minui-zero/minui-frontend.sh \&|" "$SU"
# ROMS expansion must run BEFORE muOS mounts the card: parted refuses to resize a partition that is
# in use, and a lazy unmount is not enough (it reports success while the filesystem is still busy —
# that is exactly how the first version silently did nothing). mount/start.sh is the mount step, so
# hook immediately above it.
sed -i "s|^/opt/muos/script/mount/start.sh &|[ -x /opt/minui-zero/expand-roms.sh ] \&\& /opt/minui-zero/expand-roms.sh\n/opt/muos/script/mount/start.sh \&|" "$SU"
grep -q "expand-roms.sh" "$SU" || { echo "ERROR: expand-roms pre-mount hook did not apply (startup.sh anchor changed)"; exit 1; }
echo "  expand-roms hooked pre-mount in startup.sh"
sed -i "s|^HOTKEY start|true # hotkey daemon disabled (minui owns input)|" "$SU"

# BOOT TRIM (2026-08-11). muOS keeps doing work for features this image does not ship. None of it
# blocks the menu (it is all backgrounded) but it competes for the CPU and the ~10MB/s card during
# the exact seconds the user is browsing and launching their first game.
#   catalogue.sh  - builds muOS catalogue dirs by scanning the whole rom tree. MinUI browses the
#                   filesystem directly and never reads a catalogue.
#   sdl_map.sh    - writes an SDL controller mapping. This platform does not use SDL for input at
#                   all (PLAT_pollInput reads evdev; the SDL joystick open was removed for 249ms).
sed -i "s|^/opt/muos/script/system/catalogue.sh &|true # catalogue disabled (minui browses the filesystem)|" "$SU"
sed -i "s|^/opt/muos/script/mux/sdl_map.sh &|true # sdl controller map disabled (evdev input, no SDL joystick)|" "$SU"

# MUOS FOLDER TRIM (2026-09-15, r/trimui report). A stock muOS boot litters the card root with
# folders MinUI never touches: MUOS/ (created by mount/bind.sh) plus ARCHIVE/ BACKUP/ ports/ (created
# by mount/storage.sh on every mount). We CANNOT just disable those scripts: storage.sh is what
# mounts the ROM partition MinUI reads, and startup.sh blocks the whole boot on the mount_ready flag
# that bind.sh writes (system/startup.sh: until [ -f .../mount_ready ]). So instead we redirect what
# they create off the card, leaving both scripts running and the boot gate satisfied.
#   bind.sh   - point ROM_ROOT (the on-card MUOS source tree it mkdir/bind-mounts) at a tmpfs path.
#               bind.sh still binds every location and still writes mount_ready; nothing of ours reads
#               the muOS store (our frontend owns wifi/input/saves), so tmpfs-backed + non-persistent
#               is fine. Net effect: no MUOS/ on the card.
#   storage.sh - drop BACKUP/ARCHIVE/ports from its mkdir. ROMS stays: vfat is case-insensitive so it
#               collapses into our existing Roms/ (a no-op) and keeps the union.sh primary branch.
sed -i "s|ROM_ROOT=\"\$ROM_MOUNT/MUOS\"|ROM_ROOT=/run/muos/rom-store/MUOS|" "$R/opt/muos/script/mount/bind.sh"
grep -q "ROM_ROOT=/run/muos/rom-store/MUOS" "$R/opt/muos/script/mount/bind.sh" || { echo "ERROR: MUOS-trim bind.sh anchor changed (ROM_ROOT line moved); folders would ship"; exit 1; }
sed -i "s|mkdir -p \"\$MOUNT_POINT/ROMS\" \"\$MOUNT_POINT/BACKUP\" \"\$MOUNT_POINT/ARCHIVE\" \"\$MOUNT_POINT/ports\"|mkdir -p \"\$MOUNT_POINT/ROMS\" # muOS BACKUP/ARCHIVE/ports removed (MinUI does not use them)|" "$R/opt/muos/script/mount/storage.sh"
grep -q "muOS BACKUP/ARCHIVE/ports removed" "$R/opt/muos/script/mount/storage.sh" || { echo "ERROR: MUOS-trim storage.sh anchor changed (mkdir line moved); folders would ship"; exit 1; }
echo "  muOS folder trim applied (MUOS off-card via bind.sh, ARCHIVE/BACKUP/ports dropped from storage.sh)"

# muOS also auto-connects wifi at boot from ITS saved config, while our frontend runs the same
# connect a moment later using the credentials from wifi.txt. Two connects race each other over one
# wpa_supplicant. Ours is the one that knows the user current credentials, so turn muOS off and let
# the frontend own wifi end to end (it also carries the reconnect monitor).
printf "0" > "$R/opt/muos/config/settings/network/boot"
mkdir -p "$R/opt/minui-zero"
cp /a/minui-frontend.sh "$R/opt/minui-zero/minui-frontend.sh"
cp /a/expand-roms.sh "$R/opt/minui-zero/expand-roms.sh"
chmod +x "$R/opt/minui-zero/expand-roms.sh"
[ -f /a/installing.raw ] && cp /a/installing.raw "$R/opt/minui-zero/installing.raw"
chmod +x "$R/opt/minui-zero/minui-frontend.sh"
# NO wifi credentials baked into the image (privacy): WIPE muOS saved creds from the rdumped rootfs.
# It bakes the builder network at /opt/muos/config/network/{ssid,pass} (net.sh no-ops on empty SSID),
# so after this wifi is driven SOLELY by the USER-SUPPLIED wifi.txt (SSID:password) at the SD-card
# root at boot, MinUI-style. Ship a commented example.
: > "$R/opt/muos/config/network/ssid" 2>/dev/null || true
: > "$R/opt/muos/config/network/pass" 2>/dev/null || true
rm -f "$R/etc/wpa_supplicant.conf" 2>/dev/null || true
# ssh access: dropbear (the frontend launches dropbearmulti) reads /root/.ssh/authorized_keys for
# key auth. openssh is stripped, so its host-key perm dance is gone with it.
#
# PURGE THE INHERITED KEY FIRST. The donor rootfs was dumped from a working card that already had an
# authorized_keys installed, so it carries one of its own. Release mode only removed the key we COPY
# IN ($ASSETS/authorized_keys) and left that inherited file alone, and the frontend starts dropbear
# whenever the file is non-empty. A published image therefore authorized ONE developer key on every
# user device and opened a listening port (confirmed present in the built v1.6.0 image, Codex review
# 2026-08-14). Deleting it unconditionally is what makes release mode mean anything.
# NOTE: no apostrophes anywhere in this docker block, it is one single-quoted string and an
# apostrophe closes it early, which is how this very edit first broke the script.
rm -f "$R/root/.ssh/authorized_keys"
mkdir -p "$R/root/.ssh"
if [ "$MODE" = dev ]; then
	cp /a/authorized_keys "$R/root/.ssh/authorized_keys" 2>/dev/null || true
fi
chmod 700 "$R/root/.ssh" 2>/dev/null || true

echo "  wiring ALSA-direct audio (pipewire removed)..."
# Route the default ALSA PCM straight to the codec (plug = auto rate/format/channel convert),
# replacing the muOS default->pipewire routing. Survives boot: pipewire.sh RESTORE_CONF copies
# from /opt/muos/share/conf (stripped), finds no source, and leaves this file untouched.
cat > "$R/etc/asound.conf" <<"ASOUND"
pcm.!default {
    type plug
    slave.pcm "hw:0,0"
}
ctl.!default {
    type hw
    card 0
}
ASOUND
# CHARGE MODE: muOS runs /opt/muos/script/device/charge.sh when the device is powered on by the
# charger (battery/boot_mode==1). It drops the governor to powersave and hands the screen to
# `muxcharge` — which lives in /opt/muos/frontend and is REMOVED by the strip above. The call then
# fails, the following integer test on a missing /tmp/charger_exit throws, and boot continues by
# accident rather than by design. Make it deliberate: skip the block so charge mode boots straight
# to MinUI, whose own ChargingScreen draws a filled battery AND the live percentage
# (PLAT_getChargePercent) instead of a static logo that can never show status
# (Dan 2026-08-10: the static logo "is wrong and does not show status").
CHG="$R/opt/muos/script/device/charge.sh"
if [ -f "$CHG" ]; then
	{
		echo "#!/bin/sh"
		echo "# MinUI Zero: muxcharge is stripped; MinUI renders the charge screen itself."
		echo "exit 0"
	} > "$CHG"
	chmod +x "$CHG"
fi

# Trim pipewire.sh (startup.sh still runs it at boot) to the ONE thing still needed: restoring the
# codec mixer state (unmute + output routing) from asound.state under /opt/muos/device (kept).
# Drops the pipewire daemon start and the wpctl finalise, whose ~6-9s of timeouts would otherwise
# stall every boot now. minui volume then drives the digital-volume mixer directly (libmsettings).
cat > "$R/opt/muos/script/system/pipewire.sh" <<"PWSH"
#!/bin/sh
# MinUI Zero: pipewire removed; keep only the codec init startup.sh needs at boot.
case "$1" in
start) alsactl -U -f /opt/muos/device/control/asound.state restore 2>/dev/null ;;
esac
exit 0
PWSH
chmod +x "$R/opt/muos/script/system/pipewire.sh"

# RELEASE GATE ON THE ARTIFACT, not on the inputs. The previous gate checked only the key we copy
# IN, so the one the donor rootfs already carried shipped anyway (Codex review 2026-08-14). Assert
# against the tree that is about to become the image.
if [ "$MODE" = release ]; then
	if [ -s "$R/root/.ssh/authorized_keys" ]; then
		echo "ERROR: release rootfs still carries /root/.ssh/authorized_keys"; exit 1
	fi
	if [ -e "$R/mnt/mmc/devmode.txt" ]; then
		echo "ERROR: release rootfs carries devmode.txt"; exit 1
	fi
	echo "  release gate (rootfs): no ssh key, no devmode.txt"
fi

# EVERY BOOT-CRITICAL SCRIPT MUST BE EXECUTABLE, asserted, not assumed. startup.sh calls
# expand-roms.sh behind a [ -x ] guard, so a file that lands non-executable is not an error at
# boot: the guard simply skips it, first boot never expands the card, and the failure is silent.
# This exact failure (an expander shipped 0644, guarded by [ -x ], first boot showing NO SYSTEM
# FOUND) is a known one on this class of image. Same reasoning applies: a chmod that quietly did
# not take must fail the BUILD, not the device.
for _crit in /opt/minui-zero/expand-roms.sh /opt/minui-zero/minui-frontend.sh \
             /opt/muos/script/system/startup.sh; do
	if [ ! -f "$R$_crit" ]; then
		echo "ERROR: boot-critical script missing from the rootfs: $_crit"; exit 1
	fi
	if [ ! -x "$R$_crit" ]; then
		echo "ERROR: boot-critical script is not executable: $_crit"
		echo "       a [ -x ] guard would skip it at boot and the failure would be silent."
		exit 1
	fi
done
echo "  boot-critical scripts: present and executable"

echo "  stripped rootfs size: $(du -sh $R | cut -f1)"
echo "  building lean p5 (${P5_KB}k)..."
mke2fs -q -F -t ext4 -d "$R" -L rootfs /a/out/p5.img ${P5_KB}k
'
fi

# ---- p6: FAT32 ROMS + our minui payload (mtools, no mount) ----
echo "== building FAT ROMS payload (p6) =="
STAGE="$OUT_DIR/card"; rm -rf "$STAGE"
mkdir -p "$STAGE/.system/h700/bin" "$STAGE/.system/h700/lib" "$STAGE/.system/h700/cores" \
         "$STAGE/.system/res" "$STAGE/.userdata/h700/logs" "$STAGE/.userdata/shared/.minui" \
         "$STAGE/Saves" "$STAGE/Bios" \
         "$STAGE/Roms/1) Game Boy Color (GBC)" \
         "$STAGE/Roms/2) Game Boy Advance (GBA)" \
         "$STAGE/Roms/3) Nintendo (FC)" \
         "$STAGE/Roms/4) Super Nintendo (SUPA)" \
         "$STAGE/Roms/5) Sega Genesis (MD)" \
         "$STAGE/Roms/6) PlayStation (PS)"
# Ship the six launch-tested h700 systems as empty template folders so a fresh card shows the user
# exactly where each system's roms go (numeric prefix = launcher sort order; the (TAG) maps to the
# emu pak). h700-only for now (tg5040/miyoomini ship a zip onto the user card, not a flashed image).
cp "$REPO/workspace/all/minui/build/h700/minui.elf"     "$STAGE/.system/h700/bin/"
cp "$REPO/workspace/all/minarch/build/h700/minarch.elf" "$STAGE/.system/h700/bin/"
# Shared UI helpers every tool pak calls by bare name (the frontend puts this dir on PATH). Without
# them the Deep Sleep tool, the only way to turn deep sleep OFF without ssh, now that it ships on
# by default, dies at its first confirm.elf.
for _h in confirm say settings clock status; do
	cp "$REPO/workspace/all/$_h/build/h700/$_h.elf" "$STAGE/.system/h700/bin/" 2>/dev/null || \
		{ echo "ERROR: $_h.elf missing for h700, run 'make h700-build' first"; exit 1; }
done
cp "$REPO/workspace/h700/libmsettings/libmsettings.so"  "$STAGE/.system/h700/lib/"
# card-side libs (2026-09-17): libnl-tiny.so for hostapd (both lifted from the TrimUI firmware,
# same aarch64 glibc; Device Sync hosts its hotspot with hostapd, wpa_supplicant AP mode dies
# on the RTL8821CS when a client associates)
for _l in "$REPO"/skeleton/SYSTEM/h700/lib/*; do [ -f "$_l" ] && cp "$_l" "$STAGE/.system/h700/lib/"; done
cp "$REPO/skeleton/SYSTEM/tg5040/bin/dropbearmulti"     "$STAGE/.system/h700/bin/dropbearmulti"  # ssh (openssh stripped); aarch64, shared with tg5040
chmod +x "$STAGE/.system/h700/bin/dropbearmulti"
# Shipped shell helpers from the skeleton, notably `suspend`, the deep-sleep choreography that
# PWR_deepSleep() looks for at ${BIN_PATH}/suspend. Without it the C side silently falls back to a
# bare `echo mem` with no radio teardown and no mixer restore, i.e. the EBUSY-and-dead-audio path.
for _b in "$REPO"/skeleton/SYSTEM/h700/bin/*; do
	[ -f "$_b" ] || continue
	cp "$_b" "$STAGE/.system/h700/bin/"
	chmod +x "$STAGE/.system/h700/bin/$(basename "$_b")"
done
cp "$REPO"/workspace/tg5040/cores/output/*.so           "$STAGE/.system/h700/cores/"
cp "$REPO"/skeleton/SYSTEM/res/*                        "$STAGE/.system/res/"
cp -R "$REPO"/skeleton/SYSTEM/h700/paks                 "$STAGE/.system/h700/paks"
# system.cfg: frontend defaults + the LOCKS that hide options whose PLAT_ hooks are still stubs on
# this platform (effects, sharpness, tearing, debug HUD). Without it the in-game Options > Frontend
# menu offered choices that silently did nothing (Dan 2026-08-11). minarch reads SYSTEM_PATH/system.cfg.
[ -f "$REPO/skeleton/SYSTEM/h700/system.cfg" ] && \
	cp "$REPO/skeleton/SYSTEM/h700/system.cfg" "$STAGE/.system/h700/system.cfg"
# Tools paks live at the CARD ROOT (Tools/<platform>/), not in .system — that is where minui scans
# (minui.c: SDCARD_PATH "/Tools/" PLATFORM) and where users drop community tools. h700 shipped none
# at all while the Brick ships five; Clock is the first (parity audit 2026-08-10). clock.elf is the
# shared workspace/all/clock binary, already built for this platform by `make h700-build`.
if [ -d "$REPO/skeleton/EXTRAS/Tools/h700" ]; then
	mkdir -p "$STAGE/Tools/h700"
	cp -R "$REPO"/skeleton/EXTRAS/Tools/h700/* "$STAGE/Tools/h700/"
	# clock.elf now ships in .system/h700/bin (Settings > Date & Time, 2026-09-16), copied above
	[ -f "$REPO/workspace/all/minput/build/h700/minput.elf" ] && \
		cp "$REPO/workspace/all/minput/build/h700/minput.elf" "$STAGE/Tools/h700/Input.pak/"
	# Files ships the h700 build of DinguxCommander (same source and libs as the Brick's, which
	# resolve on the lean rootfs, checked on-device; but the PLATFORM_H700 key table, because the H's
	# pad arrives as keyboard keys and the Brick's joystick table left it unusable, 2026-09-15). It is
	# produced by workspace/tg5040/makefile alongside the Brick binary. Refuse to ship the Brick
	# binary in its place: that is exactly the broken state this replaces.
	DC="$REPO/workspace/tg5040/other/DinguxCommander-sdl2"
	if [ -d "$STAGE/Tools/h700/Files.pak" ]; then
		[ -f "$DC/DinguxCommander-h700" ] || { echo "ERROR: DinguxCommander-h700 missing; run 'make tg5040' (its early target builds both Files binaries)"; exit 1; }
		cp "$DC/DinguxCommander-h700" "$STAGE/Tools/h700/Files.pak/DinguxCommander"
		cp -R "$DC/res" "$STAGE/Tools/h700/Files.pak/" 2>/dev/null || true
	fi
fi
# CORE COVERAGE GATE. The image advertises one pak per system, but the cores are whatever happens
# to be sitting in the tg5040 output directory, so a partially built core tree silently produced an
# image where two thirds of the menu cannot launch anything. That shipped: v1.6.0 as first built had
# 15 paks backed by 5 cores, and PS1 was a 10KB stub rather than a real core (found 2026-08-14 when
# PS1 games would not start). Every pak must have a core, and a core must be big enough to be real.
MISSING=""
for _pak in "$STAGE"/.system/h700/paks/Emus/*.pak; do
	[ -d "$_pak" ] || continue
	_tag=$(basename "$_pak" .pak)
	_core=$(grep -oE "[a-z0-9_]+_libretro\.so" "$_pak/launch.sh" 2>/dev/null | head -1)
	[ -n "$_core" ] || continue
	_path="$STAGE/.system/h700/cores/$_core"
	[ -f "$_path" ] || MISSING="$MISSING $_tag:$_core(absent)"
done
if [ -n "$MISSING" ]; then
	echo "ERROR: paks without a core, $MISSING"
	echo "       build the full core set first: make -C workspace/tg5040/cores (or make tg5040)"
	exit 1
fi
echo "  core coverage: every emu pak names a core that exists"

# Then validate those cores the same way `make package` does. This path is how the 10,840-byte
# pcsx_rearmed reached three devices, and it never ran the shared gate — it re-implemented only the
# size half, so a valid-header core built for the wrong architecture packaged unchallenged. The two
# checks are complementary: the loop above proves coverage (a pak with no core), this proves the
# artifacts are real (Codex review 2026-08-14, round 2).
sh "$REPO/workspace/all/cores/check-payload.sh" "$STAGE/.system/h700" h700

# version.txt (minui about screen reads .system/version.txt as "release" + "commit"; a missing
# file crashed minui on a home-screen MENU tap before the code guard, 2026-08-06)
printf 'MinUI Zero (%s)\n%s\n' "$VERSION" "$(cd "$REPO" && git rev-parse --short HEAD)" > "$STAGE/.system/version.txt"

# BOARD NAME, written at build time because the device cannot work it out at runtime. The launcher
# used to read muOS's /opt/muos/device/config/board/name, which does not exist on a rootfs that is
# not muOS, and the device-tree fallback cannot help either: this board reports "sun50iw9" for BOTH
# the Plus and the H, matching neither. DEVICE therefore fell back to "plus" on every board,
# silently correct on a Plus and WRONG on an H, which is the one where it decides whether the
# analog sticks exist (found on the first allowlist boot, 2026-08-27). The image is already built
# per device, so the answer belongs in the payload rather than in a guess.
printf '%s\n' "${DEVICE#rg35xx-}" > "$STAGE/.system/h700/board"
[ -n "$H700_TEST_ROM" ] && [ -f "$H700_TEST_ROM" ] && cp "$H700_TEST_ROM" "$STAGE/Roms/1) Game Boy Color (GBC)/"
# example wifi.txt at the card root (commented out; user adds their own "SSID:password")
printf '# WiFi: one network per line as SSID:password (# comments ignored). Example:\n# MyNetwork:mypassword\n' > "$STAGE/wifi.txt.example"
# ssh is opt-in and key-only: drop your public key here as authorized_keys and the frontend installs
# it at boot (and only then starts dropbear). No key, no listening port.
printf '# SSH: rename this to "authorized_keys" and paste your ssh PUBLIC key (one per line).\n# Without it dropbear never starts. Password login is not supported.\n' > "$STAGE/authorized_keys.example"
if [ "$MODE" = dev ]; then
	# devmode.txt, DEV CARD FLAG (api.c PWR_init arms /tmp/stay_awake at every startup when present).
	# Without it an idle h700 goes to sleep after ~2.5min: 30s -> faux-sleep, then the 2-minute deep
	# sleep escalation suspends to RAM (PLAT_supportsDeepSleep()==1 since the 2026-08-13 validation; before
	# that it fell through to PWR_powerOff(), api.c:2506, which is what the next line describes).
	# That killed every remote debug session on 2026-08-09. Delete this file to restore stock power
	# behaviour (autosleep + idle power-off), it costs idle battery, so it must NOT ship in a release.
	printf 'MinUI Zero dev flag: keeps the device awake (no autosleep, no idle power-off) so SSH sessions\nsurvive. Delete this file for stock power behaviour / best battery life.\n' > "$STAGE/devmode.txt"
fi

# Release gate: assert the dev conveniences really are absent. Cheap, and the failure it prevents is
# invisible, a shipped image that never sleeps, or that trusts the builder's ssh key on every device.
if [ "$MODE" = release ]; then
	if [ -e "$STAGE/devmode.txt" ]; then
		echo "ERROR: release payload contains devmode.txt (stay-awake would ship)"; exit 1
	fi
	if [ -s "$ASSETS/authorized_keys" ]; then
		echo "ERROR: release build has a baked ssh key at $ASSETS/authorized_keys"; exit 1
	fi
	echo "  release gate: no devmode.txt, no baked ssh key"
fi

rm -f "$OUT_DIR/p6.img"
dd if=/dev/zero of="$OUT_DIR/p6.img" bs=512 count=$P6_SECTORS status=none
"$MT/mformat" -i "$OUT_DIR/p6.img" -F -v ZERO ::
for entry in "$STAGE"/* "$STAGE"/.[!.]*; do
	[ -e "$entry" ] || continue
	COPYFILE_DISABLE=1 "$MT/mcopy" -i "$OUT_DIR/p6.img" -s "$entry" ::
done

# ---- assemble ----
echo "== assembling image =="
rm -f "$IMG"
# NOTE: raw-36mb carries the Allwinner boot chain INCLUDING the kernel DTB, which is PATCHED
# (2026-08-10, .notes/.../patch_pollinterval.py): gpio_keys poll-interval 20ms -> 5ms + recomputed
# toc1 checksum. That is the all-systems input-lag fix (buttons are kernel-POLLED on this BSP;
# mainline uses interrupts). A re-dumped part from a stock card would silently regress to 20ms —
# re-run the patch script against any fresh dump (offsets + verified algorithm inside it).
if [ -n "$BUILT_RAW" ]; then cp "$BUILT_RAW" "$IMG"; else gunzip -c "$ASSETS/parts/raw-36mb.img.gz" > "$IMG"; fi
# PER-DEVICE PARTS: parts-<device>/<file> overrides the shared part. Every board currently carries the
# PLUS kernel as its p4 (see the fail-closed kernel note above for why, and what it costs).
part() { if [ -f "$ASSETS/parts-$DEVICE/$1" ]; then echo "$ASSETS/parts-$DEVICE/$1"; else echo "$ASSETS/parts/$1"; fi; }
# `gunzip -c X | dd ...` reports DD exit status, and /bin/sh has no pipefail, so a truncated or
# corrupt part produced a short write, a zero exit, and a fully assembled image that cannot boot.
# Decompress to a temp file first so set -e actually sees the failure.
unz() { gunzip -c "$1" > "$OUT_DIR/.part.tmp"; }
unz "$(part p2-boot.img.gz)";   dd if="$OUT_DIR/.part.tmp" of="$IMG" bs=512 seek=90112  conv=notrunc status=none
unz "$(part p3-env.img.gz)";    dd if="$OUT_DIR/.part.tmp" of="$IMG" bs=512 seek=155648 conv=notrunc status=none
BOOTIMG_BYTES=$(gunzip -c "$(part p4-kernel.img.gz)" | head -c 48 | python3 -c 'import sys,struct;d=sys.stdin.buffer.read(48);k,_,r=struct.unpack("<III",d[8:20]);pg=struct.unpack("<I",d[36:40])[0];print(pg*(1+(k+pg-1)//pg+(r+pg-1)//pg))')
unz "$(part p4-kernel.img.gz)"; head -c "$BOOTIMG_BYTES" "$OUT_DIR/.part.tmp" | dd of="$IMG" bs=512 seek=188416 conv=notrunc status=none
dd if="$OUT_DIR/p5.img" of="$IMG" bs=512 seek=$P5_FIRST conv=notrunc status=none
dd if="$OUT_DIR/p6.img" of="$IMG" bs=512 seek=$P6_FIRST conv=notrunc status=none
python3 "$REPO/tools/h700-image/gpt.py" "$IMG" $TOTAL $P5_LAST $P6_FIRST $P6_LAST
rm -f "$OUT_DIR/p5.img" "$OUT_DIR/p6.img"
xz -9 -T0 -f -k "$IMG"
echo ""
echo "IMAGE: $IMG ($(du -h "$IMG" | cut -f1) on disk)  DOWNLOAD: $IMG.xz ($(du -h "$IMG.xz" | cut -f1))"
echo "Flash: diskutil unmountDisk /dev/diskN && sudo dd if=$IMG of=/dev/rdiskN bs=4m  (NEVER the muOS card)"
