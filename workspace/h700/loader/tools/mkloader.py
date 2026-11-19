#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0+
"""mkloader.py zero_params.h <objcopy -O binary output> <zero-loader.bin>

Turns the raw loader image into what the SPL accepts (zero_params.h, struct zero_loader_hdr): pads to a multiple of
512 bytes, fills length (whole image), entry (64), version (1) and the checksum: the sum of every 32-bit little-endian
word of the image, mod 2^32, with the sum field itself counted as ZL_SUM_STAMP (as eGON, zero_vendor.c zv_egon_sum).
Constants come from zero_params.h, the contract with the SPL. Run with python3 -I.
"""
import hashlib
import os
import re
import struct
import sys

IMAGE_MAX = 512 * 1024  # our own limit (README); the contract allows up to ZL_LOAD_MAX - 64 KiB
OFF_LENGTH, OFF_ENTRY, OFF_SUM, OFF_VERSION, OFF_RESERVED = 8, 12, 16, 20, 24


def contract(path):
    text = open(path, encoding="ascii").read()

    def num(name):
        m = re.search(r"^#define\s+%s\s+(0x[0-9a-fA-F]+|\d+)" % name, text, re.M)
        if not m:
            sys.exit("mkloader: %s not found in %s" % (name, path))
        return int(m.group(1), 0)

    m = re.search(r'^#define\s+ZL_HDR_MAGIC\s+"([^"]{8})"', text, re.M)
    if not m:
        sys.exit("mkloader: ZL_HDR_MAGIC not found in %s" % path)
    return {"magic": m.group(1).encode("ascii"), "stamp": num("ZL_SUM_STAMP"), "hdr_len": num("ZL_HDR_LEN"),
            "load_max": num("ZL_LOAD_MAX"), "version": num("ZL_IMAGE_VERSION")}


def checksum(img, stamp):
    words = struct.unpack("<%dI" % (len(img) // 4), img)
    return (sum(words) - words[OFF_SUM // 4] + stamp) & 0xFFFFFFFF


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    c = contract(sys.argv[1])
    img = bytearray(open(sys.argv[2], "rb").read())
    if len(img) < c["hdr_len"] + 4 or img[:8] != c["magic"]:
        sys.exit("mkloader: %s does not start with the %r header" % (sys.argv[2], c["magic"]))
    if any(img[OFF_RESERVED+4:c["hdr_len"]]):
        sys.exit("mkloader: reserved header words are not zero")
    preflight = struct.unpack_from("<I", img, OFF_RESERVED)[0]
    if preflight < c["hdr_len"] or preflight > len(img)-4 or preflight % 4:
        sys.exit("mkloader: invalid preflight entry")
    if struct.unpack_from("<I", img, OFF_ENTRY)[0] != c["hdr_len"]:
        sys.exit("mkloader: entry field is not %d (start.S)" % c["hdr_len"])
    img += bytes(-len(img) % 512)
    limit = min(IMAGE_MAX, c["load_max"] - 64 * 1024)
    if len(img) > limit:
        sys.exit("mkloader: image is %d bytes, over the %d limit" % (len(img), limit))
    struct.pack_into("<IIII", img, OFF_LENGTH, len(img), c["hdr_len"], 0, c["version"])
    struct.pack_into("<I", img, OFF_SUM, checksum(img, c["stamp"]))
    # verify the way the SPL will: recompute over the finished image
    if checksum(img, c["stamp"]) != struct.unpack_from("<I", img, OFF_SUM)[0] or len(img) % 512:
        sys.exit("mkloader: self-check failed")
    tmp = sys.argv[3] + ".part"
    with open(tmp, "wb") as f:
        f.write(img)
    os.replace(tmp, sys.argv[3])
    print("mkloader: %s %d bytes (%d KiB of %d), sum 0x%08x, md5 %s" % (
        sys.argv[3], len(img), len(img) // 1024, limit // 1024, struct.unpack_from("<I", img, OFF_SUM)[0],
        hashlib.md5(img).hexdigest()))


if __name__ == "__main__":
    main()
