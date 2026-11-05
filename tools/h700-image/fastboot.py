#!/usr/bin/env python3
"""Faster H700 boot files, derived from each board's pinned muOS inputs by oneimage.py (boot speed, 2026-11-04).

The vendor code is unchanged; only its inputs change. The method follows BaseOS by pvaibhav (its docs/12-kernel-gzip.md
describes the same seven changes); this is our own implementation against our own muOS files, which carry muOS device
trees and so are not the stock files BaseOS pins. Measured on the RG35XX H (warm reboots, .notes/2026-11-04-boot-speed):
quiet kernel console and fast RCU ~0.3 s, silent boot0 and U-Boot ~0.55 s, no initramfs ~0.2 s warm and its 1 s wait on
cold starts. Every function asserts that no byte outside the intended ones changed.

  package   U-Boot: one instruction selects gzip for Android images (movw r3,#0x200 stores comp=NONE,type=KERNEL at
            image_info+92; #0x201 makes comp=GZIP), U-Boot's and the package's checksums; and the package device tree's
            /soc/platform debug_mode 3 -> 0 (U-Boot prints nothing to the serial port).
  boot0     header byte 0x34 debug_mode 3 -> 0 and its checksum (boot0 prints nothing).
  boot.img  the kernel stored as gzip -9 (byte-identical once unpacked), an empty initramfs (the kernel mounts root= itself;
            the rootfs inittab mounts /proc, /sys, /dev and remounts / with the options the initramfs used), and the header
            cmdline field, which U-Boot appends to bootargs: loglevel=1 (only panics reach the serial port; dmesg keeps all),
            expedited RCU while the kernel starts, and three unused vendor drivers skipped (see CMDLINE).
The package and boot.img must be installed together: the patched U-Boot cannot boot a raw kernel, nor the stock one a gzip
kernel. boardpick.sh always installs a board's package and kernel as one set.
"""
import gzip, io, struct

STAMP = 0x5F0A6C39            # Allwinner checksum seed (eGON/TOC1)
UBOOT_AT = 2048               # U-Boot's place in every one of our 11 boot packages
SELECTOR = 63128              # in U-Boot: the Android image_info compression/type store
SELECTOR_CONTEXT = bytes.fromhex('4ff400733046a4f85c30052384f85e30')   # movw.w r3,#512; mov r0,r6; strh r3,[r4,#92]; ...
SELECTOR_GZIP = bytes.fromhex('40f20123')                              # movw r3,#0x201
# initcall_blacklist skips three built-in vendor drivers nothing on this image uses: deeplay_encrypt (/dev/deeplayer, a
# vendor crypto device, 35 ms), vin (camera input, 20 ms), brd (RAM block devices, 12 ms); measured -0.08 s on the H. A
# kernel without one of them just ignores the name.
CMDLINE = (b'loglevel=1 rcupdate.rcu_expedited=1 rcupdate.rcu_normal_after_boot=1 '
           b'initcall_blacklist=deeplay_encrypt_init,vin_init,brd_init')
BOOT0_DEBUG = 0x34
LATE_USB = ('ehci1-controller', 'ohci1-controller', 'ohci2-controller', 'ehci3-controller', 'ohci3-controller')
LATE_MMC = ('sdmmc@04022000', 'sdmmc@04021000')   # second card slot (sdc2) and WiFi (sdc1); the main card is sdmmc@04020000


def word(b, o):
    return struct.unpack_from('<I', b, o)[0]


def checksum(b, field):
    assert len(b) % 4 == 0, 'unaligned Allwinner block'
    return (sum(struct.unpack('<%dI' % (len(b) // 4), b)) - word(b, field) + STAMP) & 0xFFFFFFFF


def changed(a, b):
    assert len(a) == len(b), 'length changed'
    return {i for i, (x, y) in enumerate(zip(a, b)) if x != y}


def _items(pkg):
    assert pkg[:16] == b'sunxi-package\0\0\0' and word(pkg, 16) == 0x89119800, 'not an Allwinner TOC1 package'
    assert word(pkg, 36) == len(pkg) and checksum(pkg, 20) == word(pkg, 20), 'bad package length/checksum'
    out = {}
    for i in range(word(pkg, 32)):
        pos = 64 + 368 * i
        out[bytes(pkg[pos:pos + 64]).split(b'\0')[0].decode()] = struct.unpack_from('<2I', pkg, pos + 64)
    return out


def _fdt_prop(dtb, node, prop):
    """(offset, length) of `prop`'s value in the first node named `node` (unit address ignored unless `node` has one)."""
    magic, total, off_struct, off_strings = struct.unpack_from('>4I', dtb, 0)
    assert magic == 0xd00dfeed and total <= len(dtb), 'not a flattened device tree'
    pos, stack = off_struct, []
    while True:
        tok = struct.unpack_from('>I', dtb, pos)[0]
        pos += 4
        if tok == 1:
            end = dtb.index(b'\0', pos)
            full = dtb[pos:end].decode()
            stack.append(full if '@' in node else full.split('@')[0])
            pos = (end + 4) & ~3
        elif tok == 2:
            stack.pop()
        elif tok == 3:
            ln, nameoff = struct.unpack_from('>2I', dtb, pos)
            pos += 8
            name = dtb[off_strings + nameoff:dtb.index(b'\0', off_strings + nameoff)].decode()
            if stack and stack[-1] == node and name == prop:
                return pos, ln
            pos = (pos + ln + 3) & ~3
        elif tok == 4:
            pass
        elif tok == 9:
            raise KeyError('%s/%s not in the device tree' % (node, prop))
        else:
            raise ValueError('bad device tree token %d' % tok)


def package(orig):
    """The gzip selector and debug_mode 0 in one boot package."""
    pkg = bytearray(orig)
    items = _items(pkg)
    start, size = items['u-boot']
    assert start == UBOOT_AT, 'U-Boot not at %d' % UBOOT_AT
    ub = bytearray(pkg[start:start + size])
    assert word(ub, 20) == len(ub) and checksum(ub, 12) == word(ub, 12), 'bad U-Boot length/checksum'
    assert ub[SELECTOR:SELECTOR + len(SELECTOR_CONTEXT)] == SELECTOR_CONTEXT, 'U-Boot compression selector not found'
    ub[SELECTOR:SELECTOR + 4] = SELECTOR_GZIP
    struct.pack_into('<I', ub, 12, checksum(ub, 12))
    pkg[start:start + size] = ub
    dstart, dsize = items['dtb']
    off, ln = _fdt_prop(bytes(pkg[dstart:dstart + dsize]), 'platform', 'debug_mode')
    assert ln == 4 and pkg[dstart + off:dstart + off + 4] == struct.pack('>I', 3), 'debug_mode is not 3'
    pkg[dstart + off:dstart + off + 4] = bytes(4)
    allowed = (set(range(20, 24)) | set(range(start + 12, start + 16)) | set(range(start + SELECTOR, start + SELECTOR + 4))
               | set(range(dstart + off, dstart + off + 4)))
    # USB host controllers held back from the kernel's start-up (~0.36 s on the H); zero_late_usb.ko starts them once the
    # menu is up. "late" is any status but "okay" to the kernel, and the module only touches nodes that say exactly
    # "late". The OTG port's own controllers (ehci0/ohci0) and EHCI 2 are left alone.
    for node in LATE_USB:
        o, ln = _fdt_prop(bytes(pkg[dstart:dstart + dsize]), node, 'status')
        assert ln == 5 and pkg[dstart + o:dstart + o + 5] == b'okay\0', node + ' status is not okay'
        pkg[dstart + o:dstart + o + 5] = b'late\0'
        allowed |= set(range(dstart + o, dstart + o + 4))
    # The second card slot and WiFi, held back the same way (~0.13 s on the H); zero_late_mmc.ko starts both from early.sh,
    # second card first, so the hosts keep their boot numbers (mmc1, mmc2). All 11 boards have both enabled.
    for node in LATE_MMC:
        o, ln = _fdt_prop(bytes(pkg[dstart:dstart + dsize]), node, 'status')
        assert ln == 5 and pkg[dstart + o:dstart + o + 5] == b'okay\0', node + ' status is not okay'
        pkg[dstart + o:dstart + o + 5] = b'late\0'
        allowed |= set(range(dstart + o, dstart + o + 4))
    struct.pack_into('<I', pkg, 20, checksum(pkg, 20))
    assert changed(orig, pkg) <= allowed, 'package changed outside the selector, debug_mode and checksums'
    return bytes(pkg)


def boot0(orig):
    """debug_mode 0 in boot0's header. On a card boot0 rewrites its own first sector at every boot (DRAM training), so
    the picker installs the board's file whole, as it always has."""
    b = bytearray(orig)
    assert b[4:12] == b'eGON.BT0' and word(b, 0x10) == len(b) == 65536 and checksum(b, 12) == word(b, 12), 'bad boot0'
    assert b[BOOT0_DEBUG] == 3, 'boot0 debug_mode is not 3'
    b[BOOT0_DEBUG] = 0
    struct.pack_into('<I', b, 12, checksum(b, 12))
    assert changed(orig, b) <= {12, 13, 14, 15, BOOT0_DEBUG}
    return bytes(b)


def empty_cpio():
    """A newc archive holding only its TRAILER!!! record, one 512-byte block: an initramfs with nothing in it."""
    hdr = b'070701' + b'00000000' * 4 + b'00000001' + b'00000000' * 6 + b'0000000B' + b'00000000'
    return (hdr + b'TRAILER!!!\0').ljust(512, b'\0')


def bootimg(orig):
    """The gzip kernel, an empty initramfs and the cmdline in one trimmed Android v2 boot image (page 2048)."""
    d = bytes(orig)
    assert d[:8] == b'ANDROID!' and word(d, 40) == 2 and word(d, 36) == 2048, 'not an Android v2 boot image, page 2048'
    assert word(d, 24) == 0 and d[64:576] == bytes(512), 'unexpected second stage or a non-empty cmdline'
    pg = lambda n: (n + 2047) // 2048 * 2048
    ks = word(d, 8)
    kernel = d[2048:2048 + ks]
    assert len(kernel) == ks and kernel[0x38:0x3C] == b'ARM\x64', 'kernel is not an uncompressed ARM64 Image'
    s = io.BytesIO()
    with gzip.GzipFile(fileobj=s, mode='wb', compresslevel=9, mtime=0, filename='') as g:
        g.write(kernel)
    packed = s.getvalue()
    assert gzip.decompress(packed) == kernel, 'gzip roundtrip failed'
    rd = empty_cpio()
    head = bytearray(d[:2048])
    struct.pack_into('<I', head, 8, len(packed))
    struct.pack_into('<I', head, 16, len(rd))
    head[64:576] = CMDLINE.ljust(512, b'\0')
    assert changed(d[:2048], head) <= set(range(8, 12)) | set(range(16, 20)) | set(range(64, 64 + len(CMDLINE))), \
        'header changed outside the sizes and cmdline'
    return bytes(head) + packed + bytes(pg(len(packed)) - len(packed)) + rd + bytes(pg(len(rd)) - len(rd))


def is_fast(d):
    """True for a boot image this module made (gzip kernel): the stager and verifier never transform one twice."""
    return d[:8] == b'ANDROID!' and d[2048:2050] == b'\x1f\x8b'


def initramfs_files(orig, names):
    """{name: bytes} for the files named (by basename) in a stock boot image's gzip newc initramfs: e2fsck and its
    libraries move to the rootfs, which runs it only when the kernel has recorded errors on the root filesystem."""
    d = bytes(orig)
    pg = lambda n: (n + 2047) // 2048 * 2048
    ks, rs = word(d, 8), word(d, 16)
    cpio = gzip.decompress(d[2048 + pg(ks):2048 + pg(ks) + rs])
    out, pos, links, regular = {}, 0, {}, {}
    while True:
        assert cpio[pos:pos + 6] == b'070701', 'not a newc archive'
        f = [int(cpio[pos + 6 + 8 * i:pos + 14 + 8 * i], 16) for i in range(13)]
        mode, fsize, nsize = f[1], f[6], f[11]
        name = cpio[pos + 110:pos + 110 + nsize - 1].decode()
        dpos = (pos + 110 + nsize + 3) & ~3
        data = cpio[dpos:dpos + fsize]
        pos = (dpos + fsize + 3) & ~3
        if name == 'TRAILER!!!':
            break
        base = name.rsplit('/', 1)[-1]
        if (mode & 0o170000) == 0o120000:
            links[base] = data.decode().rsplit('/', 1)[-1]
        elif (mode & 0o170000) == 0o100000:
            regular[base] = data
    for base in names:                          # libfoo.so.2 -> libfoo.so.2.3: the target's bytes under the asked name
        t, hops = base, 0
        while t in links and t not in regular and hops < 8:
            t, hops = links[t], hops + 1
        if t in regular:
            out[base] = regular[t]
    missing = set(names) - set(out)
    assert not missing, 'not in the initramfs: ' + ', '.join(sorted(missing))
    return out
