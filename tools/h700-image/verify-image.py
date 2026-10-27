#!/usr/bin/env python3
"""Verify a finished H700 image against the pinned inputs it was built from (assets.sha256).

  verify-image.py IMG DEVICE [--assets DIR] [--version vX.Y.Z] [--release] [--no-docker]

Checks, each against bytes rebuilt from the pinned assets rather than a remembered md5:
  boot chain   the first 36 MiB (boot0 x2, u-boot, the board's patched device tree) equal what bootchain.py
               and the boot0 override produce for DEVICE; LPDDR3 boards carry dram type 7
  p2 p3 p4     the boot, env and kernel partitions equal the board's parts
  payload      .system/version.txt names the expected version (mtools); a release carries no devmode.txt
  rootfs       (docker debugfs) root locked, dropbear key-only, muOS lid.sh and boot-time WiFi off, GPU
               ceiling, no baked ssh key on a release, and the /opt/muos/device overlay is this board's
Replaces the per-release scratch verify-images.py / verify-rootfs.py copies in .notes.
"""
import gzip, hashlib, os, struct, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
RAW36 = 36 << 20
BOOT0_OFFS = (8192, 262144)
SECTOR = 512
P2, P3, P4 = 90112, 155648, 188416       # build-h700-stripped.sh dd seeks
LPDDR3 = ('rg35xx-pro', 'rg40xx-h', 'rg40xx-v')

fails = []


def check(name, ok, detail=''):
    print('  %-34s %s%s' % (name, 'ok' if ok else 'FAIL', ('  ' + detail) if detail else ''))
    if not ok:
        fails.append(name)


def part(assets, device, name):
    own = os.path.join(assets, 'parts-' + device, name)
    return own if os.path.isfile(own) else os.path.join(assets, 'parts', name)


def gpt(f):
    f.seek(SECTOR)
    h = f.read(92)
    if h[:8] != b'EFI PART':
        return None
    lba, n, sz = struct.unpack('<QII', h[72:88])
    f.seek(lba * SECTOR)
    out = {}
    for _ in range(n):
        e = f.read(sz)
        first, last = struct.unpack('<QQ', e[32:48])
        if first:
            out[e[56:128].decode('utf-16-le').rstrip('\0')] = (first, last)
    return out


def expected_chain(assets, device, tmp):
    base = os.path.join(tmp, 'base.img')
    with gzip.open(os.path.join(assets, 'parts', 'raw-36mb.img.gz')) as g, open(base, 'wb') as o:
        o.write(g.read())
    pkg = '-' if device == 'rg35xx-plus' else os.path.join(assets, 'device-' + device, 'package', 'boot_package.fex')
    out = os.path.join(tmp, 'chain.img')
    subprocess.run([sys.executable, os.path.join(HERE, 'bootchain.py'), base, pkg, out], check=True, capture_output=True)
    chain = bytearray(open(out, 'rb').read())
    b0 = os.path.join(assets, 'parts-' + device, 'boot0.img')
    if device != 'rg35xx-plus' and os.path.isfile(b0):
        b = open(b0, 'rb').read()
        for off in BOOT0_OFFS:
            chain[off:off + len(b)] = b
    return bytes(chain)


def debugfs(img, off, path):
    d, base = os.path.split(os.path.abspath(img))
    r = subprocess.run(['docker', 'run', '--rm', '--platform', 'linux/amd64', '-v', d + ':/img:ro', 'tg5040-toolchain',
                        'debugfs', '-R', 'cat ' + path, '/img/%s?offset=%d' % (base, off)], capture_output=True)
    return r.stdout


def main():
    args, opts, it = [], {}, iter(sys.argv[1:])
    for a in it:
        if a in ('--assets', '--version'):
            opts[a] = next(it)
        elif a.startswith('--'):
            opts[a] = True
        else:
            args.append(a)
    if len(args) != 2:
        sys.exit(__doc__)
    img, device = args
    assets = opts.get('--assets', os.environ.get('H700_ASSETS', os.path.join(REPO, '.notes', '2026-08-05-h700-image')))
    print('== %s (%s)' % (os.path.basename(img), device))

    r = subprocess.run([sys.executable, os.path.join(HERE, 'check-assets.py'), assets, device, '--no-rootfs'],
                       capture_output=True, text=True)
    check('assets match the manifest', r.returncode == 0, (r.stdout + r.stderr).strip().splitlines()[-1] if r.returncode else '')

    with open(img, 'rb') as f:
        parts = gpt(f)
        check('GPT with rootfs + roms', bool(parts) and 'rootfs' in parts and len(parts) >= 6,
              ' '.join(sorted(parts)) if parts else 'no GPT')

        with tempfile.TemporaryDirectory() as tmp:
            want = expected_chain(assets, device, tmp)
        f.seek(0)
        have = f.read(RAW36)
        # bytes 0..2047 are the protective MBR + GPT header + 8-entry table, rewritten by gpt.py
        check('boot chain (2 KiB..36 MiB)', have[2048:] == want[2048:])
        b0 = have[BOOT0_OFFS[0]:BOOT0_OFFS[0] + 65536]
        check('boot0 copies identical', b0 == have[BOOT0_OFFS[1]:BOOT0_OFFS[1] + 65536])
        dram = struct.unpack('<I', b0[0x3c:0x40])[0]
        if device in LPDDR3:
            check('boot0 LPDDR3 primary', dram == 7, 'dram type %d' % dram)

        for name, seek in (('p2-boot.img.gz', P2), ('p3-env.img.gz', P3), ('p4-kernel.img.gz', P4)):
            with gzip.open(part(assets, device, name)) as g:
                data = g.read()
            if name.startswith('p4'):   # the build writes only the Android boot image's own length
                k, _, r_ = struct.unpack('<III', data[8:20])
                pg = struct.unpack('<I', data[36:40])[0]
                data = data[:pg * (1 + (k + pg - 1) // pg + (r_ + pg - 1) // pg)]
            f.seek(seek * SECTOR)
            check(name.split('.')[0] + ' matches ' + os.path.relpath(part(assets, device, name), assets),
                  f.read(len(data)) == data)

    roms = parts.get('roms') if parts else None
    mtype = '/opt/homebrew/bin/mtype'
    if roms and os.path.exists(mtype):
        spec = '%s@@%d' % (img, roms[0] * SECTOR)
        ver = subprocess.run([mtype, '-i', spec, '::/.system/version.txt'], capture_output=True, text=True).stdout
        check('version.txt', bool(ver) and (not opts.get('--version') or '(%s)' % opts['--version'] in ver),
              ver.splitlines()[0] if ver else 'missing')
        if opts.get('--release'):
            dm = subprocess.run([mtype, '-i', spec, '::/devmode.txt'], capture_output=True).returncode
            check('no devmode.txt on the card', dm != 0)
    else:
        print('  (payload checks skipped: no roms partition or no mtools)')

    if opts.get('--no-docker') or not parts or 'rootfs' not in parts:
        print('  (rootfs checks skipped)')
    else:
        off = parts['rootfs'][0] * SECTOR
        cat = lambda p: debugfs(img, off, p)
        shadow = cat('/etc/shadow').decode(errors='replace')
        fe = cat('/opt/minui-zero/minui-frontend.sh').decode(errors='replace')
        start = cat('/opt/muos/script/device/start.sh').decode(errors='replace')
        mod = cat('/opt/muos/script/device/module.sh').decode(errors='replace')
        root = next((l for l in shadow.splitlines() if l.startswith('root:')), '')
        drop = [l.strip() for l in fe.splitlines() if 'dropbear -' in l and not l.strip().startswith('#')]
        check('root password locked', root.startswith('root:!:'))
        check('dropbear key-only (-s)', bool(drop) and all(' dropbear -s ' in l for l in drop), '%d start lines' % len(drop))
        check('muOS lid.sh off', 'lid.sh start &' not in start and 'muOS lid.sh disabled' in start)
        check('WiFi not loaded at boot', 'WiFi driver not loaded at boot' in mod)
        check('GPU ceiling 648 MHz', 'MinUI Zero GPU ceiling 648 MHz' in mod)
        if opts.get('--release'):
            check('no baked ssh key', not cat('/root/.ssh/authorized_keys').strip())
        if device != 'rg35xx-plus':
            want_pkg = open(os.path.join(assets, 'device-' + device, 'package', 'boot_package.fex'), 'rb').read()
            have_pkg = cat('/opt/muos/device/package/boot_package.fex')
            check('rootfs device overlay is ' + device, hashlib.sha256(have_pkg).digest() == hashlib.sha256(want_pkg).digest())

    print('== %s: %s' % (device, 'PASS' if not fails else 'FAIL (%s)' % ', '.join(fails)))
    sys.exit(1 if fails else 0)


if __name__ == '__main__':
    main()
