#!/usr/bin/env python3
"""Build an Allwinner boot chain (the first 36MB of the card) for a given H700 device.

WHY THIS EXISTS
---------------
muOS selects a device at IMAGE-BUILD time: each device folder in MustardOS/internal carries its own
`package/boot_package.fex`, which holds u-boot + the device tree for that board. PROVEN here: the
1310720-byte blob at offset 16793600 of our boot chain is byte-identical to the published
`boot_package.fex` (our copy differs by exactly 2 bytes, our own poll-interval patch). So a
different device's boot chain is a SUBSTITUTION at a known offset, not a separate 1GB donor image.

That matters because the device tree is what makes hardware exist: the RG35XX H tree enables a GPADC
plus an analog mux (the two sticks) and adds keyL3/keyR3, none of which the Plus tree has. Without
the H tree the sticks are invisible to the kernel no matter what userspace does.

THE INPUT-LAG PATCH TRAVELS WITH IT
-----------------------------------
This BSP *polls* gpio-keys rather than using interrupts, at 20ms. We rewrite poll-interval to 5ms.
The old script hardcoded an absolute byte offset, which silently means "Plus only", a different
device tree puts it elsewhere. This one PARSES the flattened device tree and finds every
poll-interval property, so it is correct for any board, and it recomputes the Allwinner toc1
additive checksum afterwards or the SoC refuses to boot.
"""
import struct, sys, os

PKG_OFF   = 16793600          # where boot_package lives inside the 36MB boot chain
PKG_LEN   = 1310720           # its length (== every published boot_package.fex)
TOC1_HEAD = 16793600          # toc1 header == package head
VALID_LEN = 1310720
STAMP     = 0x5F0A6C39        # value the checksum field holds while summing
ADD_SUM_OFF = 0x14            # toc1 layout: name[16] magic add_sum -> checksum at +20, not +12
NEW_MS    = 5
FDT_MAGIC = b'\xd0\x0d\xfe\xed'

FDT_BEGIN_NODE, FDT_END_NODE, FDT_PROP, FDT_NOP, FDT_END = 1, 2, 3, 4, 9


def find_fdt(buf):
    """Return (offset, size) of the single real FDT blob inside a boot package.

    Validates that the blob actually FITS and that its structure/string blocks lie inside it. Without
    that, a header claiming a larger totalsize than the package holds still parsed far enough to find
    and patch poll-interval, and toc1_fix() would then wrap a valid outer checksum around an
    internally invalid device tree, i.e. a chain that passes every check here and does not boot.
    Fail closed instead: a boot chain we cannot fully verify is not one to ship.
    """
    off = 0
    while True:
        i = buf.find(FDT_MAGIC, off)
        if i < 0:
            return None
        total = struct.unpack_from('>I', buf, i + 4)[0]
        ver = struct.unpack_from('>I', buf, i + 20)[0]
        if 0x1000 < total < 4_000_000 and ver in (16, 17) and i + total <= len(buf):
            off_struct, off_strings = struct.unpack_from('>II', buf, i + 8)
            size_strings = struct.unpack_from('>I', buf, i + 12 + 12)[0]  # header: ...strings size
            if 0 < off_struct < total and 0 < off_strings <= total and off_strings + size_strings <= total:
                return i, total
        off = i + 4


def find_poll_intervals(fdt):
    """Walk the FDT structure block; yield (value_offset_within_fdt, current_value, node_path)."""
    off_struct, off_strings = struct.unpack_from('>II', fdt, 8)
    depth, path = [], []
    p = off_struct
    while p < len(fdt):
        (tag,) = struct.unpack_from('>I', fdt, p)
        p += 4
        if tag == FDT_BEGIN_NODE:
            end = fdt.index(b'\x00', p)
            path.append(fdt[p:end].decode('ascii', 'replace'))
            p = (end + 4) & ~3
        elif tag == FDT_END_NODE:
            if path:
                path.pop()
        elif tag == FDT_PROP:
            length, nameoff = struct.unpack_from('>II', fdt, p)
            p += 8
            nend = fdt.index(b'\x00', off_strings + nameoff)
            name = fdt[off_strings + nameoff:nend].decode('ascii', 'replace')
            if name == 'poll-interval' and length == 4:
                (val,) = struct.unpack_from('>I', fdt, p)
                yield p, val, '/'.join(path)
            p = (p + length + 3) & ~3
        elif tag in (FDT_NOP,):
            continue
        elif tag == FDT_END:
            return
        else:
            return


def toc1_fix(buf):
    """Recompute the Allwinner toc1 additive checksum over the package.

    Layout is `name[16] magic add_sum`, so add_sum sits at +20 (0x14), NOT +12. Writing it at +12
    clobbers the tail of the name field and leaves the real checksum stale, which is a boot chain the
    SoC rejects. Caught by the self-test that rebuilds the known-good Plus chain and demands a
    byte-for-byte match; keep that test, it is the only thing standing between a typo and a device
    that will not boot.
    """
    struct.pack_into('<I', buf, TOC1_HEAD + ADD_SUM_OFF, STAMP)
    total = 0
    for i in range(TOC1_HEAD, TOC1_HEAD + VALID_LEN, 4):
        (w,) = struct.unpack_from('<I', buf, i)
        total = (total + w) & 0xFFFFFFFF
    struct.pack_into('<I', buf, TOC1_HEAD + ADD_SUM_OFF, total)
    return total


def build(base_raw, package, out_raw):
    raw = bytearray(open(base_raw, 'rb').read())
    if len(raw) < PKG_OFF + PKG_LEN:
        sys.exit(f"ERROR: {base_raw} is only {len(raw)} bytes, too small to hold a boot package")

    pkg = open(package, 'rb').read()
    if len(pkg) != PKG_LEN:
        sys.exit(f"ERROR: {package} is {len(pkg)} bytes, expected {PKG_LEN}")
    if pkg[:13] != b'sunxi-package':
        sys.exit(f"ERROR: {package} does not start with the sunxi-package magic")

    raw[PKG_OFF:PKG_OFF + PKG_LEN] = pkg
    print(f"  substituted boot package from {os.path.basename(package)} at {PKG_OFF}")

    found = find_fdt(raw[PKG_OFF:PKG_OFF + PKG_LEN])
    if not found:
        sys.exit("ERROR: no device tree found inside the boot package")
    fdt_off, fdt_size = found
    abs_fdt = PKG_OFF + fdt_off
    fdt = bytes(raw[abs_fdt:abs_fdt + fdt_size])
    print(f"  device tree at package+{fdt_off} ({fdt_size} bytes)")

    hits = list(find_poll_intervals(fdt))
    if not hits:
        sys.exit("ERROR: no poll-interval property in this device tree, refusing to guess")
    patched = 0
    for voff, val, node in hits:
        if val <= NEW_MS:   # already as fast or faster (newer trees ship 4 ms): never slow it down
            print(f"  {node}/poll-interval already {val}ms (<= {NEW_MS}ms), left alone")
            continue
        struct.pack_into('>I', raw, abs_fdt + voff, NEW_MS)
        print(f"  {node}/poll-interval {val}ms -> {NEW_MS}ms  (at {abs_fdt + voff})")
        patched += 1

    chk = toc1_fix(raw)
    print(f"  toc1 checksum recomputed: 0x{chk:08X}  ({patched} propert{'y' if patched==1 else 'ies'} changed)")

    open(out_raw, 'wb').write(bytes(raw))
    print(f"  wrote {out_raw} ({len(raw)} bytes)")


if __name__ == '__main__':
    if len(sys.argv) != 4:
        sys.exit(f"usage: {sys.argv[0]} <base-raw-36mb.img> <boot_package.fex> <out-raw-36mb.img>")
    build(*sys.argv[1:])
