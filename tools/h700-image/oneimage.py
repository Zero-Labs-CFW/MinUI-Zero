#!/usr/bin/env python3
"""Stage every H700 board's boot files for the ONE image (H700_DEVICE=all, Dan 2026-10-30).

    oneimage.py <assets> <base-raw36.img> <out-dir>

For each board writes <out-dir>/<board>/:
  package.fex     its boot package (u-boot + device tree), patched by bootchain.py exactly as its own image is
  boot0.img       its own boot0 (parts-<board>/boot0.img; the Plus, H and SP share the base chain's)
  kernel          the name of its kernel in <out-dir>/kernels/ (<sha256 prefix>.img.gz): the partition contents,
                  trimmed to the Android boot image's own length, stored once however many boards share one
  device.tar.gz   its /opt/muos/device overlay (the Plus's is taken from the rootfs inside the docker step)
tools/h700-strip/boardpick.sh installs these on the device. Board inputs and rules are the per-board build's
(build-h700-stripped.sh): one muOS commit per board for kernel + package, LPDDR3 boot0 where required.
"""
import gzip, hashlib, os, struct, subprocess, sys, tarfile

PKG_OFF, PKG_LEN = 16793600, 1310720
HERE = os.path.dirname(os.path.abspath(__file__))
BOARDS_TXT = os.path.join(os.path.dirname(os.path.dirname(HERE)), 'workspace', 'h700', 'boards.txt')


def read_boards(path=BOARDS_TXT):
    """The board table (workspace/h700/boards.txt), the one list of H700 boards: {id: set of flags}, in table order."""
    out = {}
    for line in open(path):
        f = line.split()
        if not f or f[0].startswith('#'):
            continue
        assert len(f) >= 11, 'boards.txt: short row: ' + line.strip()
        out[f[0]] = set() if f[8] == '-' else set(f[8].split(','))
    assert out, 'boards.txt: no boards'
    return out


_TABLE = read_boards()
BOARDS = list(_TABLE)
OWN_BOOT0_OPTIONAL = {b for b, fl in _TABLE.items() if 'plusboot0' in fl}   # Anbernic's stock boot0 equals the Plus's
LPDDR3 = {b for b, fl in _TABLE.items() if 'lpddr3' in fl}


def boot0_ok(b, need_lpddr3):
    ln = struct.unpack('<I', b[16:20])[0]
    assert b[4:12] == b'eGON.BT0' and len(b) == ln == 65536, 'bad boot0 magic/length'
    y = bytearray(b); y[12:16] = struct.pack('<I', 0x5F0A6C39)
    assert sum(struct.unpack('<%dI' % (ln // 4), bytes(y))) & 0xffffffff == struct.unpack('<I', b[12:16])[0], 'bad boot0 checksum'
    assert not need_lpddr3 or struct.unpack('<I', b[0x3c:0x40])[0] == 7, 'needs an LPDDR3-primary boot0'


def bootimg_len(d):  # Android boot image: header page + kernel + ramdisk, each page-rounded (as the build trims p4)
    k, _, r = struct.unpack('<III', d[8:20])
    pg = struct.unpack('<I', d[36:40])[0]
    assert d[:8] == b'ANDROID!', 'kernel partition is not an Android boot image'
    return pg * (1 + (k + pg - 1) // pg + (r + pg - 1) // pg)


def main(assets, base, out):
    base_boot0 = open(base, 'rb').read(8192 + 65536)[8192:]
    for b in BOARDS:
        d = os.path.join(out, b)
        os.makedirs(d, exist_ok=True)
        pkg = '-' if b == 'rg35xx-plus' else os.path.join(assets, 'device-' + b, 'package', 'boot_package.fex')
        chain = os.path.join(out, '.chain.img')
        subprocess.run([sys.executable, os.path.join(HERE, 'bootchain.py'), base, pkg, chain], check=True,
                       stdout=subprocess.DEVNULL)
        with open(chain, 'rb') as f:
            f.seek(PKG_OFF)
            open(os.path.join(d, 'package.fex'), 'wb').write(f.read(PKG_LEN))
        os.remove(chain)

        own = os.path.join(assets, 'parts-' + b, 'boot0.img')
        if os.path.isfile(own):
            b0 = open(own, 'rb').read()
        else:
            assert b in OWN_BOOT0_OPTIONAL, b + ' has no boot0 of its own'
            b0 = base_boot0
        boot0_ok(b0, b in LPDDR3)
        open(os.path.join(d, 'boot0.img'), 'wb').write(b0)

        kpath = os.path.join(assets, 'parts' if b == 'rg35xx-plus' else 'parts-' + b, 'p4-kernel.img.gz')
        assert os.path.isfile(kpath), b + ' has no kernel at ' + kpath
        k = gzip.open(kpath).read()
        k = k[:bootimg_len(k)]
        kname = hashlib.sha256(k).hexdigest()[:16] + '.img.gz'
        os.makedirs(os.path.join(out, 'kernels'), exist_ok=True)
        kfile = os.path.join(out, 'kernels', kname)
        if not os.path.isfile(kfile):
            with gzip.open(kfile, 'wb', compresslevel=9) as g:
                g.write(k)
        open(os.path.join(d, 'kernel'), 'w').write(kname + '\n')

        if b != 'rg35xx-plus':
            src = os.path.join(assets, 'device-' + b)
            assert os.path.isfile(os.path.join(src, 'config', 'board', 'name')), b + ' has no device overlay'
            with tarfile.open(os.path.join(d, 'device.tar.gz'), 'w:gz') as t:
                for e in sorted(os.listdir(src)):
                    t.add(os.path.join(src, e), arcname=e)
        print('  %-12s package, boot0 (dram type %d), kernel %d KB%s' % (
            b, struct.unpack('<I', b0[0x3c:0x40])[0], len(k) // 1024,
            '' if b == 'rg35xx-plus' else ', device overlay'))


if __name__ == '__main__':
    main(*sys.argv[1:4])
