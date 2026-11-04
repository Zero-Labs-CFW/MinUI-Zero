#!/usr/bin/env python3
"""Verify a finished H700 image against the pinned inputs it was built from (assets.sha256).

  verify-image.py IMG DEVICE [--assets DIR] [--version vX.Y.Z] [--release] [--no-docker]

DEVICE "all" is the one image: the Plus chain and kernel under the universal (RG35XX Pro) boot0, and every
board's boot files staged in /opt/minui-zero/boards equal to what oneimage.py builds from the pinned assets.

Checks, each against bytes rebuilt from the pinned assets rather than a remembered md5:
  boot chain   the first 36 MiB (boot0 x2, u-boot, the board's patched device tree) equal what bootchain.py
               and the boot0 override produce for DEVICE; LPDDR3 boards carry dram type 7
  p2 p3 p4     the boot, env and kernel partitions equal the board's parts
  payload      .system/version.txt names the expected version (mtools); a release carries no devmode.txt
  rootfs       (docker debugfs) root locked, dropbear key-only, muOS lid.sh and boot-time WiFi off, GPU
               ceiling, no baked ssh key on a release, and the /opt/muos/device overlay is this board's
Replaces the per-release scratch verify-images.py / verify-rootfs.py copies in .notes.
"""
import filecmp, gzip, io, os, shutil, struct, subprocess, sys, tarfile, tempfile, zlib

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from oneimage import bootimg_len, BOARDS, LPDDR3   # the p4 trim and the board table, shared with the stager
REPO = os.path.dirname(os.path.dirname(HERE))
RAW36 = 36 << 20
BOOT0_OFFS = (8192, 262144)
SECTOR = 512
P2, P3, P4 = 90112, 155648, 188416       # build-h700-stripped.sh dd seeks
ALL = tuple(BOARDS)   # workspace/h700/boards.txt

fails = []


def check(name, ok, detail=''):
    print('  %-34s %s%s' % (name, 'ok' if ok else 'FAIL', ('  ' + detail) if detail else ''))
    if not ok:
        fails.append(name)


def part(assets, device, name):
    if device == 'all':   # the one image ships the Plus parts; a stray parts-all must not be blessed
        device = 'rg35xx-plus'
    own = os.path.join(assets, 'parts-' + device, name)
    return own if os.path.isfile(own) else os.path.join(assets, 'parts', name)


def gpt_table(f, hdr_lba):
    """One GPT copy: (header ok, entry array bytes) or None. The header and array CRCs must hold, as the
    kernel requires before it trusts either copy."""
    f.seek(hdr_lba * SECTOR)
    h = f.read(SECTOR)
    if h[:8] != b'EFI PART':
        return None
    hsize, hcrc = struct.unpack('<II', h[12:20])
    lba, n, sz, acrc = struct.unpack('<QIII', h[72:92])
    ok = zlib.crc32(h[:16] + b'\0\0\0\0' + h[20:hsize]) == hcrc
    f.seek(lba * SECTOR)
    arr = f.read(n * sz)
    return ok and zlib.crc32(arr) == acrc, arr, n, sz, struct.unpack('<Q', h[32:40])[0]


def gpt(f):
    p = gpt_table(f, 1)
    if not p:
        return None
    ok, arr, n, sz, backup = p
    b = gpt_table(f, backup)
    out = {'(valid primary + backup GPT)': ok and bool(b) and b[0] and b[1] == arr}
    for i in range(n):
        e = arr[i * sz:(i + 1) * sz]
        first, last = struct.unpack('<QQ', e[32:48])
        # a zero type GUID marks the entry unused, so the kernel would not create the partition at all
        if first and e[:16] != b'\0' * 16:
            out[e[56:128].decode('utf-16-le').rstrip('\0')] = (first, last)
    return out


def expected_chain(assets, device, tmp):
    base = os.path.join(tmp, 'base.img')
    with gzip.open(os.path.join(assets, 'parts', 'raw-36mb.img.gz')) as g, open(base, 'wb') as o:
        o.write(g.read())
    pkg = '-' if device in ('rg35xx-plus', 'all') else os.path.join(assets, 'device-' + device, 'package', 'boot_package.fex')
    out = os.path.join(tmp, 'chain.img')
    subprocess.run([sys.executable, os.path.join(HERE, 'bootchain.py'), base, pkg, out], check=True, capture_output=True)
    chain = bytearray(open(out, 'rb').read())
    b0 = os.path.join(assets, 'parts-' + ('rg35xx-pro' if device == 'all' else device), 'boot0.img')
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


def debugfs_mode(img, off, path):
    """The inode mode of PATH in the rootfs (e.g. 0o100755), or None when it does not exist."""
    d, base = os.path.split(os.path.abspath(img))
    r = subprocess.run(['docker', 'run', '--rm', '--platform', 'linux/amd64', '-v', d + ':/img:ro', 'tg5040-toolchain',
                        'debugfs', '-R', 'stat ' + path, '/img/%s?offset=%d' % (base, off)], capture_output=True, text=True)
    for tok in r.stdout.replace('\n', ' ').split('Mode:')[1:2]:
        return int(tok.split()[0], 8)
    return None


def rdump(img, off, path, out):
    """Copy a rootfs directory out of the image into OUT; returns the copy or None."""
    d, base = os.path.split(os.path.abspath(img))
    subprocess.run(['docker', 'run', '--rm', '--platform', 'linux/amd64', '-v', d + ':/img:ro', '-v', out + ':/out',
                    'tg5040-toolchain', 'debugfs', '-R', 'rdump %s /out' % path, '/img/%s?offset=%d' % (base, off)],
                   capture_output=True)
    got = os.path.join(out, os.path.basename(path))
    return got if os.path.isdir(got) else None


def boards_diff(assets, have, tmp, plus_device):
    """The one image's staged boards (HAVE, rdumped) against oneimage.py run on the pinned assets. Compressed files
    are compared by content: gzip and tar headers carry build-time stamps."""
    base = os.path.join(tmp, 'base.img')
    with gzip.open(os.path.join(assets, 'parts', 'raw-36mb.img.gz')) as g, open(base, 'wb') as o:
        o.write(g.read())
    want = os.path.join(tmp, 'boards')
    subprocess.run([sys.executable, os.path.join(HERE, 'oneimage.py'), assets, base, want], check=True, capture_output=True)
    out = []
    for b in ALL:
        for n in ('package.fex', 'boot0.img', 'kernel'):
            a, h = os.path.join(want, b, n), os.path.join(have, b, n)
            if not os.path.isfile(h) or not filecmp.cmp(a, h, shallow=False):
                out.append('%s/%s' % (b, n))
        k = open(os.path.join(want, b, 'kernel')).read().strip()
        hk = os.path.join(have, 'kernels', k)
        if not os.path.isfile(hk) or gzip.open(hk).read() != gzip.open(os.path.join(want, 'kernels', k)).read():
            out.append('%s kernel %s' % (b, k))
        td = os.path.join(have, b, 'device.tar.gz')
        if not os.path.isfile(td):
            out.append(b + '/device.tar.gz missing')
            continue
        x = os.path.join(tmp, 'dev-' + b)
        with tarfile.open(td) as t:
            t.extractall(x)
        if b == 'rg35xx-plus':   # the donor rootfs's own tree: equal to the image's /opt/muos/device, naming the Plus
            if open(os.path.join(x, 'config', 'board', 'name')).read().strip() != 'rg35xx-plus':
                out.append('rg35xx-plus device files do not name the Plus')
            out += ['rg35xx-plus device %s' % d for d in (tree_diff(plus_device, x) if plus_device else ['rdump failed'])]
        else:
            out += ['%s device %s' % (b, d) for d in tree_diff(os.path.join(assets, 'device-' + b), x)]
    return out


def tree_diff(a, b):
    """Paths that differ between two trees: missing on either side, or different bytes or symlink target."""
    out = []
    for root, dirs, files in os.walk(a):
        rel = os.path.relpath(root, a)
        other = os.path.join(b, rel)
        theirs = set(os.listdir(other)) if os.path.isdir(other) else set()
        for n in dirs + files:
            p, q = os.path.join(root, n), os.path.join(other, n)
            r = os.path.normpath(os.path.join(rel, n))
            if n not in theirs:
                out.append('missing ' + r)
            elif os.path.islink(p) or os.path.islink(q):
                if not (os.path.islink(p) and os.path.islink(q) and os.readlink(p) == os.readlink(q)):
                    out.append('link ' + r)
            elif os.path.isfile(p) and not filecmp.cmp(p, q, shallow=False):
                out.append('differs ' + r)
        for n in theirs - set(dirs + files):
            out.append('extra ' + os.path.normpath(os.path.join(rel, n)))
    return out


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

    for d in (ALL if device == 'all' else (device,)):
        r = subprocess.run([sys.executable, os.path.join(HERE, 'check-assets.py'), assets, d, '--no-rootfs'],
                           capture_output=True, text=True)
        check('assets match the manifest' + (' (%s)' % d if device == 'all' else ''), r.returncode == 0,
              (r.stdout + r.stderr).strip().splitlines()[-1] if r.returncode else '')

    with open(img, 'rb') as f:
        parts = gpt(f)
        valid = bool(parts) and parts.pop('(valid primary + backup GPT)')
        check('GPT CRCs + backup copy', valid)
        check('GPT with rootfs + roms', bool(parts) and 'rootfs' in parts and 'roms' in parts and len(parts) >= 6,
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
        if device in LPDDR3 or device == 'all':
            check('boot0 LPDDR3 primary', dram == 7, 'dram type %d' % dram)

        for name, seek in (('p2-boot.img.gz', P2), ('p3-env.img.gz', P3), ('p4-kernel.img.gz', P4)):
            with gzip.open(part(assets, device, name)) as g:
                data = g.read()
            if name.startswith('p4'):   # the build writes only the Android boot image's own length
                data = data[:bootimg_len(data)]
            f.seek(seek * SECTOR)
            check(name.split('.')[0] + ' matches ' + os.path.relpath(part(assets, device, name), assets),
                  f.read(len(data)) == data)

    roms = parts.get('roms') if parts else None
    mtype = shutil.which('mtype') or next((p for p in ('/opt/homebrew/bin/mtype', '/usr/local/bin/mtype')
                                           if os.path.exists(p)), None)
    if roms and mtype:
        spec = '%s@@%d' % (img, roms[0] * SECTOR)
        ver = subprocess.run([mtype, '-i', spec, '::/.system/version.txt'], capture_output=True, text=True).stdout
        check('version.txt', bool(ver) and (not opts.get('--version') or '(%s)' % opts['--version'] in ver),
              ver.splitlines()[0] if ver else 'missing')
        # what the device scripts read: the board table, its reader, and the shared launch-loop log helpers
        for src, dst in (('workspace/h700/boards.txt', '.system/h700/boards.txt'),
                         ('skeleton/SYSTEM/h700/bin/board', '.system/h700/bin/board'),
                         ('skeleton/SYSTEM/res/zero-log.sh', '.system/res/zero-log.sh'),
                         ('tools/h700-strip/minui-frontend.sh', '.system/h700/bin/minui-frontend.sh')):
            got = subprocess.run([mtype, '-i', spec, '::/' + dst], capture_output=True).stdout
            check(dst + ' current', got == open(os.path.join(REPO, src), 'rb').read(), '' if got else 'missing')
        if opts.get('--release'):
            dm = subprocess.run([mtype, '-i', spec, '::/devmode.txt'], capture_output=True).returncode
            check('no devmode.txt on the card', dm != 0)
    else:
        print('  (payload checks skipped: no roms partition or no mtools)')
        # a release is only verified if every check ran: a skipped one must not read as PASS
        if opts.get('--release'):
            check('payload checks ran (mtools)', False)

    # the MinUI.zip the same build writes beside the image (card-update.sh installs it on a device): it must pass the
    # CRC test the device runs first, carry every piece card-update.sh requires, and never the picked model
    zp = os.path.join(os.path.dirname(os.path.abspath(img)), os.path.basename(img).rsplit('-', 1)[0] + '.zip')
    zip_min_rootfs = None
    if os.path.isfile(zp):
        import zipfile
        with zipfile.ZipFile(zp) as z:
            names = set(z.namelist())
            bad = z.testzip()
            fe = '.system/h700/bin/minui-frontend.sh'
            fe_ok = fe in names and z.read(fe) == open(os.path.join(REPO, 'tools/h700-strip/minui-frontend.sh'), 'rb').read()
            mr = '.system/h700/min-rootfs'
            if mr in names and z.read(mr).strip().isdigit():
                zip_min_rootfs = int(z.read(mr).strip())
        need = ['.system/h700/paks/MinUI.pak/launch.sh', '.system/h700/bin/minui.elf', '.system/h700/bin/minarch.elf',
                fe, '.system/h700/boards.txt', '.system/version.txt']
        missing = [n for n in need if n not in names] + [d for d in ('.system/h700/cores/', '.system/res/')
                                                         if not any(n.startswith(d) for n in names)]
        check('update zip CRC', bad is None, bad or '')
        check('update zip complete', not missing, ', '.join(missing))
        check('update zip has no picked model', '.system/h700/board' not in names)
        check('update zip frontend current', fe_ok)
        check('update zip states its min-rootfs', zip_min_rootfs is not None)
    elif opts.get('--release'):
        check('update zip present (%s)' % os.path.basename(zp), False)

    if opts.get('--no-docker') or not parts or 'rootfs' not in parts:
        print('  (rootfs checks skipped)')
        if opts.get('--release'):
            check('rootfs checks ran (docker)', False)
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
        # MinUI.zip updates: the rootfs frontend and its updater are this tree's, and the updater has its unzip
        for src, dst in (('tools/h700-strip/minui-frontend.sh', '/opt/minui-zero/minui-frontend.sh'),
                         ('tools/h700-strip/card-update.sh', '/opt/minui-zero/card-update.sh'),
                         ('tools/h700-strip/card-fsck.sh', '/opt/minui-zero/card-fsck.sh')):
            mode = debugfs_mode(img, off, dst)
            check(os.path.basename(dst) + ' current + executable',
                  cat(dst) == open(os.path.join(REPO, src), 'rb').read() and mode is not None and mode & 0o111 == 0o111,
                  'mode %s' % (oct(mode) if mode is not None else 'missing'))
        mode = debugfs_mode(img, off, '/usr/bin/unzip')
        check('unzip for MinUI.zip updates', mode is not None and mode & 0o111 == 0o111)
        # card-fsck.sh repairs the card before an install, so it must run before muOS mounts the card, with its fsck
        su = cat('/opt/muos/script/system/startup.sh').decode(errors='replace').splitlines()
        hook = next((i for i, l in enumerate(su) if 'card-fsck.sh' in l and not l.lstrip().startswith('#')), None)
        mnt = next((i for i, l in enumerate(su) if l.startswith('/opt/muos/script/mount/start.sh')), None)
        check('card-fsck runs before the card mounts', hook is not None and mnt is not None and hook < mnt)
        mode = debugfs_mode(img, off, '/sbin/fsck.vfat')
        check('fsck.vfat for card-fsck', mode is not None and mode & 0o111 == 0o111)
        # the rootfs level must cover what this build's own zip needs, or a fresh image refuses its own update
        lvl = cat('/opt/minui-zero/rootfs-level').decode(errors='replace').strip()
        check('rootfs-level covers the zip', lvl.isdigit() and (zip_min_rootfs is None or int(lvl) >= zip_min_rootfs),
              'rootfs %s, zip needs %s' % (lvl or 'missing', zip_min_rootfs))
        if opts.get('--release'):
            check('no baked ssh key', not cat('/root/.ssh/authorized_keys').strip())
        # The frontend reads its board (rotation, panel size, lid, rate) from config/board/name, so check
        # it on every board, and on a board with its own overlay compare the whole tree, not one file.
        name = cat('/opt/muos/device/config/board/name').decode(errors='replace').strip()
        first = 'rg35xx-plus' if device == 'all' else device   # the one image boots as a Plus until a model is chosen
        check('board/name is ' + first, name == first, name or 'missing')
        if device == 'all':
            check('frontend runs the model picker', 'boardpick.sh' in fe)
            for src, dst in (('tools/h700-strip/boardpick.sh', '/opt/minui-zero/boardpick.sh'),
                             ('workspace/h700/boardpick/build/h700/boardpick.elf', '/opt/minui-zero/boardpick.elf')):
                want = open(os.path.join(REPO, src), 'rb').read()
                mode = debugfs_mode(img, off, dst)
                check('picker ' + os.path.basename(dst) + ' current + executable',
                      cat(dst) == want and mode is not None and mode & 0o111 == 0o111,
                      'mode %s' % (oct(mode) if mode is not None else 'missing'))
            # the frontend and the picker test these by existence, so check existence, not contents
            for n in ('chosen', 'chosen.new', 'trying', 'pending', 'pending.new', 'undo-boot0.img'):
                check('no boards/' + n + ' yet', debugfs_mode(img, off, '/opt/minui-zero/boards/' + n) is None)
            with tempfile.TemporaryDirectory(dir=os.path.dirname(os.path.abspath(img))) as tmp:
                have = rdump(img, off, '/opt/minui-zero/boards', tmp)
                os.makedirs(os.path.join(tmp, 'dev'))
                plus = rdump(img, off, '/opt/muos/device', os.path.join(tmp, 'dev'))
                diff = boards_diff(assets, have, tmp, plus) if have else ['rdump failed']
            check('all %d boards staged' % len(ALL), not diff, ', '.join(diff[:5]))
        elif device != 'rg35xx-plus':
            want = os.path.join(assets, 'device-' + device)
            # beside the image: docker on macOS mounts only shared paths, and the image folder is one
            with tempfile.TemporaryDirectory(dir=os.path.dirname(os.path.abspath(img))) as tmp:
                have = rdump(img, off, '/opt/muos/device', tmp)
                diff = tree_diff(want, have) if have else ['rdump failed']
            check('rootfs device overlay is ' + device, not diff, ', '.join(diff[:5]))

    print('== %s: %s' % (device, 'PASS' if not fails else 'FAIL (%s)' % ', '.join(fails)))
    sys.exit(1 if fails else 0)


if __name__ == '__main__':
    main()
