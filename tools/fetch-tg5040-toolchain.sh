#!/bin/sh
# Pre-download the tg5040 toolchain's compiler and sysroot on the HOST, verified, into the toolchain's
# support/ folder. The union toolchain's setup-toolchain.sh wgets them inside debian/eol:buster, whose CA store
# no longer trusts developer.arm.com: the wget fails, the script carries on, and the image builds with no
# compiler at all (2026-10-30). The Dockerfile copies support/ into /root, where setup-toolchain.sh untars
# from, so files placed here are used as-is. Nothing tracked in the pinned clone is edited.
# usage: sh tools/fetch-tg5040-toolchain.sh toolchains/tg5040-toolchain/support
set -e
DIR=${1:?usage: fetch-tg5040-toolchain.sh <toolchain support dir>}
GCC=gcc-arm-8.3-2019.02-x86_64-aarch64-linux-gnu.tar.xz
GCC_MD5=456048545984d4c031565df676a324f7 # ARM's published $GCC.asc
SDK=SDK_usr_tg5040_a133p.tgz
SDK_SHA256=b6b615d03204e9d9bb1a91c31de0c3402434f6b8fc780743fa88a5f1da6f3c79 # release 20231018, hashed 2026-10-30

fetch() { # file url check-command expected
	if [ -f "$DIR/$1" ] && [ "$($3 "$DIR/$1" | cut -d ' ' -f 1)" = "$4" ]; then return; fi
	echo "fetching $1"
	curl -fL --retry 3 -o "$DIR/$1.part" "$2"
	got=$($3 "$DIR/$1.part" | cut -d ' ' -f 1)
	[ "$got" = "$4" ] || { echo "ERROR: $1 checksum $got, expected $4"; exit 1; }
	mv "$DIR/$1.part" "$DIR/$1"
}
MD5="md5 -r"; command -v md5 >/dev/null || MD5=md5sum # macOS / Linux
fetch $GCC https://developer.arm.com/-/media/Files/downloads/gnu-a/8.3-2019.02/$GCC "$MD5" $GCC_MD5
fetch $SDK https://github.com/trimui/toolchain_sdk_smartpro/releases/download/20231018/$SDK "shasum -a 256" $SDK_SHA256
