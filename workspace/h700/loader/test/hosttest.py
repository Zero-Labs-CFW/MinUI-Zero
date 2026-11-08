#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0+
"""hosttest.py: inputs for test/hosttest.c, then the run (make hosttest; python3 -I; reads files only).

From the boot.img: the 2048-byte header and the gzip kernel (+ the Image inflated by Python's zlib, the reference).
From the boot package (TOC1): the dtb and dtbo items. The pinned stock boot0 (DRAM words, board block) and the
expected bootargs: the live Plus cmdline with " disp_reserve=..." removed (the loader draws no logo).
"""
import argparse
import os
import re
import struct
import subprocess
import sys
import zlib


def toc1_items(pkg):
    if pkg[:13] != b"sunxi-package":
        sys.exit("hosttest: not a sunxi-package")
    count = struct.unpack_from("<I", pkg, 32)[0]
    items = {}
    for i in range(count):
        b = 64 + i * 368
        name = pkg[b:b + 64].split(b"\0")[0].decode()
        off, size = struct.unpack_from("<II", pkg, b + 64)
        items[name] = pkg[off:off + size]
    return items


def main():
    ap = argparse.ArgumentParser()
    for a in ("bin", "bootimg", "package", "cmdline", "out"):
        ap.add_argument("--" + a, required=True)
    ap.add_argument("--pin", default=None, help="pinned stock boot0 (default: ../pin-plus.bin)")
    a = ap.parse_args()
    here = os.path.dirname(os.path.abspath(__file__))
    pin = a.pin or os.path.join(here, "..", "..", "pin-plus.bin")
    os.makedirs(a.out, exist_ok=True)

    img = open(a.bootimg, "rb").read()
    if img[:8] != b"ANDROID!":
        sys.exit("hosttest: not a boot.img")
    ksize, kaddr = struct.unpack_from("<II", img, 8)
    page = struct.unpack_from("<I", img, 36)[0]
    gz = img[page:page + ksize]
    d = zlib.decompressobj(31)
    image = d.decompress(gz)
    if not d.eof or d.unused_data:
        sys.exit("hosttest: the reference inflate did not end cleanly")
    items = toc1_items(open(a.package, "rb").read())
    cmdline = open(a.cmdline, encoding="ascii").read().strip()
    want = re.sub(r" disp_reserve=\S+", "", cmdline)
    files = {"hdr.bin": img[:2048], "kernel.gz": gz, "Image": image, "dtb.bin": items["dtb"],
             "dtbo.bin": items.get("dtbo", b""), "pin.bin": open(pin, "rb").read(), "bootargs.txt": want.encode()}
    for name, data in files.items():
        with open(os.path.join(a.out, name), "wb") as f:
            f.write(data)
    print("hosttest: kernel %d -> %d bytes at 0x%x, dtb %d bytes, expected bootargs %d bytes" % (
        len(gz), len(image), kaddr, len(items["dtb"]), len(want)))
    sys.exit(subprocess.run([a.bin, a.out]).returncode)


if __name__ == "__main__":
    main()
