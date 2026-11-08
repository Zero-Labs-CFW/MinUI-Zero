#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0+
"""checkelf.py: post-link checks on the loader (run by make; python3 -I).

1. _start is at ZL_LOAD_ADDR + 64 (zero_params.h) and the first instruction there is _start (objdump).
2. A static executable with no relocations, GOT, PLT, dynamic or interpreter sections or segments.
3. No FP/SIMD register anywhere in the code (the monitor or the SPL may leave FP trapped).
4. zero-loader.bin: header as the SPL checks it (magic, length = file size, multiple of 512, entry 64, version 1,
   checksum), and its bytes from offset 64 equal the ELF's code at the entry.
"""
import argparse
import re
import struct
import subprocess
import sys

FAILS = []


def fail(msg):
    FAILS.append(msg)
    print("checkelf: FAIL " + msg)


def run(*args):
    return subprocess.run(list(args), check=True, capture_output=True, text=True).stdout


def contract(path):
    text = open(path, encoding="ascii").read()

    def num(name):
        return int(re.search(r"^#define\s+%s\s+(0x[0-9a-fA-F]+|\d+)" % name, text, re.M).group(1), 0)

    magic = re.search(r'^#define\s+ZL_HDR_MAGIC\s+"([^"]{8})"', text, re.M).group(1).encode("ascii")
    return num("ZL_LOAD_ADDR"), num("ZL_HDR_LEN"), num("ZL_SUM_STAMP"), magic, num("ZL_IMAGE_VERSION")


def main():
    ap = argparse.ArgumentParser()
    for a in ("params", "elf", "bin", "objdump", "readelf", "nm"):
        ap.add_argument("--" + a, required=True)
    a = ap.parse_args()
    load, hdr_len, stamp, magic, image_version = contract(a.params)
    entry = load + hdr_len

    syms = {}
    for line in run(a.nm, a.elf).splitlines():
        f = line.split()
        if len(f) == 3:
            syms[f[2]] = int(f[0], 16)
    if syms.get("_start") != entry:
        fail("_start at %s, want 0x%x" % (hex(syms.get("_start", 0)), entry))
    first = run(a.objdump, "-d", "--start-address=0x%x" % entry, "--stop-address=0x%x" % (entry + 4), a.elf)
    m = re.search(r"^\s*%x:\s+([0-9a-f]{8})\s+(.*)$" % entry, first, re.M)
    if "<_start>:" not in first or not m:
        fail("no _start instruction at 0x%x" % entry)
    else:
        print("checkelf: first instruction 0x%x <_start>: %s  %s" % (entry, m.group(1), m.group(2).strip()))

    hdr = run(a.readelf, "-h", a.elf)
    if not re.search(r"Type:\s+EXEC", hdr):
        fail("not a static executable (readelf -h Type)")
    if "There are no relocations in this file." not in run(a.readelf, "-r", a.elf):
        fail("relocations present (readelf -r)")
    sections = run(a.readelf, "-S", "-W", a.elf)
    bad = re.findall(r"\]\s+(\.got\S*|\.plt\S*|\.rela?\.\S+|\.dynamic|\.dynsym|\.dynstr|\.interp|\.hash|\.gnu\.hash)\s",
                     sections)
    if bad:
        fail("dynamic-linking sections present: %s" % " ".join(sorted(set(bad))))
    segments = run(a.readelf, "-l", "-W", a.elf)
    if re.search(r"^\s+(INTERP|DYNAMIC)\s", segments, re.M):
        fail("INTERP or DYNAMIC segment present")

    dis = run(a.objdump, "-d", "--no-show-raw-insn", a.elf)
    fp = []
    for line in dis.splitlines():
        m = re.match(r"^\s*([0-9a-f]+):\s+(\S+)\s*(.*)$", line)
        if not m:
            continue
        ops = m.group(3).split("//")[0]
        if re.search(r"\b[vqdsbh]([0-9]|[12][0-9]|3[01])\b", ops) or re.search(r"\b(fpcr|fpsr)\b", ops):
            fp.append(line.strip())
    if fp:
        fail("FP/SIMD registers used:\n  " + "\n  ".join(fp[:20]))

    img = open(a.bin, "rb").read()
    length, ent, total, version = struct.unpack_from("<IIII", img, 8)
    words = struct.unpack("<%dI" % (len(img) // 4), img)
    calc = (sum(words) - words[4] + stamp) & 0xFFFFFFFF
    preflight = struct.unpack_from("<I", img, 24)[0]
    if preflight < hdr_len or preflight > len(img)-4 or preflight % 4 or load+preflight != syms.get("zl_preflight"):
        fail("preflight header does not name executable zl_preflight")
    pf = run(a.objdump, "-d", "--start-address=0x%x" % (load+preflight),
             "--stop-address=0x%x" % (load+preflight+4), a.elf)
    if "<zl_preflight>:" not in pf:
        fail("preflight is not an instruction in .text")
    if img[:8] != magic or length != len(img) or length % 512 or ent != hdr_len or version != image_version or calc != total:
        fail("zero-loader.bin header: magic %r length %d (file %d) entry %d version %d sum 0x%08x (calc 0x%08x)" % (
            img[:8], length, len(img), ent, version, total, calc))
    raw = subprocess.run([a.objdump.replace("objdump", "objcopy"), "-O", "binary", "--only-section=.text", a.elf,
                          "/dev/stdout"], check=True, capture_output=True).stdout
    if not raw or img[hdr_len:hdr_len + len(raw)] != raw:
        fail("zero-loader.bin bytes at +%d differ from the ELF .text" % hdr_len)

    if FAILS:
        sys.exit("checkelf: %d check(s) failed" % len(FAILS))
    print("checkelf: OK (entry 0x%x, no relocations/GOT/PLT/dynamic, no FP/SIMD, %d-byte image, sum 0x%08x)" % (
        entry, len(img), total))


if __name__ == "__main__":
    main()
