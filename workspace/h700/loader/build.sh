#!/bin/sh
# Offline build. Never installs, writes a card or enables a profile.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${1:?usage: build.sh OUTPUT_DIRECTORY}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
IMAGE=${ZERO_LOADER_BUILD_IMAGE:-sha256:906796bdcb29b23d682b81bc2dba00d921ac1098ab9e417f97eb46c1e25c2123}
[ "$(docker image inspect "$IMAGE" --format '{{.Os}}/{{.Architecture}}')" = linux/arm64 ] || {
    echo 'ERROR: a local Linux arm64 toolchain image is required' >&2; exit 1;
}
docker run --rm --network none --cap-drop ALL --security-opt no-new-privileges \
    -v "$HERE:/source:ro" -v "$HERE/../boot-health:/health:ro" -v "$OUT:/out" "$IMAGE" sh -ec '
    cp -a /source /tmp/loader
    cd /tmp/loader
    make clean
    python3 -I tools/profiles.py --check
    make -j2
    cp zero-loader.bin obj/zero-loader.elf obj/zero-loader.map obj/build-id obj/sources.json /out/
    gcc -std=c11 -O2 -Wall -Wextra -Werror -static /health/boot-health.c /health/boot_health.c -o /out/boot-health
    gcc --version > /out/compiler.txt
    ld --version > /out/linker.txt
    cd /out
    sha256sum zero-loader.bin zero-loader.elf zero-loader.map build-id sources.json boot-health > artifacts.sha256
'
docker image inspect "$IMAGE" --format '{{.Id}}' > "$OUT/toolchain-image.txt"
echo "built $OUT/zero-loader.bin (not installed or hardware-qualified)"
