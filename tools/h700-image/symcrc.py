#!/usr/bin/env python3
"""symcrc.py <p4-kernel.img.gz|boot.img|Image> <symbol>...: modversions CRCs of exported symbols, read offline.

These muOS 4.9 arm64 kernels are relocatable: __ksymtab's pointers and __kcrctab's values are zero in the Image and are
filled at boot from R_AARCH64_RELATIVE records (r_offset = slot address, r_addend = value; KASLR is off, so the value
is the addend). So: collect every RELATIVE record, find the export entry whose name pointer is the symbol's string,
walk the contiguous run of entries (ksymtab then ksymtab_gpl), and read the CRC slot at kcrctab_start + 8*index,
where kcrctab_start is the address right after the run. Checked against the live H kernel (/dev/mem) and against the
CRCs the rootfs modules record.
"""
import gzip, struct, sys

TEXT = 0xffffff8008080000
RELATIVE = 0x403


def image_of(path):
    d = open(path, 'rb').read()
    if d[:2] == b'\x1f\x8b':
        d = gzip.decompress(d)
    if d[:8] == b'ANDROID!':
        ks = struct.unpack_from('<I', d, 8)[0]
        d = d[2048:2048 + ks]
        if d[:2] == b'\x1f\x8b':
            d = gzip.decompress(d)
    assert d[0x38:0x3c] == b'ARM\x64', 'not an arm64 Image'
    return d


def relocs(img):
    """{slot VA: addend} for every RELATIVE record (24-byte rela triples, 8-aligned)."""
    out = {}
    r = struct.pack('<Q', RELATIVE)
    i = img.find(r)
    while i >= 0:
        if i % 8 == 0 and i >= 8 and i + 16 <= len(img):
            off, = struct.unpack_from('<Q', img, i - 8)
            add, = struct.unpack_from('<Q', img, i + 8)
            if TEXT <= off < TEXT + 0x2000000:
                out[off] = add
        i = img.find(r, i + 1)
    return out


def crcs(img, names):
    rel = relocs(img)
    vas, j = set(), img.find(b'\0module_layout\0')   # the name can appear more than once (kallsyms, ksymtab_strings)
    while j >= 0:
        vas.add(TEXT + j + 1)
        j = img.find(b'\0module_layout\0', j + 1)
    slots = [o - 8 for o, a in rel.items() if a in vas and (o - 8) in rel]
    assert len(slots) == 1, 'module_layout export entry found %d times' % len(slots)
    ok = lambda e: e in rel and (e + 8) in rel and TEXT <= rel[e + 8] < TEXT + 0x2000000
    a = slots[0]
    while ok(a - 16):
        a -= 16
    c = slots[0]
    while ok(c):
        c += 16
    n = (c - a) // 16
    byname = {}
    for i in range(n):
        p = rel[a + 16 * i + 8] - TEXT
        nm = img[p:img.index(b'\0', p)].decode(errors='replace')
        byname[nm] = rel.get(c + 8 * i, 0) & 0xffffffff
    missing = [x for x in names if x not in byname]
    assert not missing, 'not exported: ' + ', '.join(missing)
    return {x: byname[x] for x in names}, n


if __name__ == '__main__':
    img = image_of(sys.argv[1])
    res, n = crcs(img, sys.argv[2:])
    print('# %d exported symbols' % n)
    for k, v in res.items():
        print('0x%08x\t%s\tvmlinux\tEXPORT_SYMBOL' % (v, k))


def module_versions(ko):
    """{symbol: crc} from a kernel module's __versions section (64-bit ELF: 8-byte crc + 56-byte name per entry)."""
    d = open(ko, 'rb').read() if isinstance(ko, str) else ko
    assert d[:4] == b'\x7fELF' and d[4] == 2, 'not a 64-bit ELF'
    shoff, = struct.unpack_from('<Q', d, 0x28)
    shentsize, shnum, shstrndx = struct.unpack_from('<HHH', d, 0x3a)
    secs = [struct.unpack_from('<IIQQQQIIQQ', d, shoff + i * shentsize) for i in range(shnum)]
    stroff = secs[shstrndx][4]
    out = {}
    for s in secs:
        if d[stroff + s[0]:d.index(b'\0', stroff + s[0])] == b'__versions':
            for i in range(0, s[5], 64):
                crc, = struct.unpack_from('<Q', d, s[4] + i)
                out[d[s[4] + i + 8:s[4] + i + 64].split(b'\0')[0].decode()] = crc & 0xffffffff
    return out
