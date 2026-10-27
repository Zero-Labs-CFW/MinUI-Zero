#!/usr/bin/env python3
"""Check the per-board H700 image inputs against tools/h700-image/assets.sha256.

The build reads gitignored files (the muOS dump, the boot chain parts, each board's boot_package,
boot0, kernel and /opt/muos/device overlay) from the asset folder of whichever checkout runs it. A
clone missing one, or holding a stale copy, used to build a plausible image for the wrong hardware.
This resolves the exact files build-h700-stripped.sh will read for a board, using the same rules,
and fails unless every one matches the manifest. A board with no manifest entry fails too.

  check-assets.py ASSETS DEVICE [--no-rootfs]     verify (the build calls this)
  check-assets.py ASSETS DEVICE --write            print this board's manifest lines from ASSETS

--no-rootfs skips muos-p5.img, for builds given an external p5 (H700_P5).
"""
import hashlib, os, sys

MANIFEST = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'assets.sha256')


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for block in iter(lambda: f.read(1 << 20), b''):
            h.update(block)
    return h.hexdigest()


def sha256_tree(root):
    # one hash over every file's relative path + content, so an added, removed or edited file changes it
    h = hashlib.sha256()
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        for name in sorted(filenames):
            p = os.path.join(dirpath, name)
            h.update(os.path.relpath(p, root).encode() + b'\0' + sha256_file(p).encode() + b'\n')
    return h.hexdigest()


def inputs(assets, device, rootfs):
    """(manifest key, path, kind) for every file the build reads for this board, mirroring the build script."""
    out = []
    if rootfs:
        out.append(('muos-p5.img', os.path.join(assets, 'muos-p5.img'), 'file'))
    out.append(('parts/raw-36mb.img.gz', os.path.join(assets, 'parts', 'raw-36mb.img.gz'), 'file'))
    own = os.path.join(assets, 'parts-' + device)
    for name in ('p2-boot.img.gz', 'p3-env.img.gz', 'p4-kernel.img.gz'):   # part(): the board's own copy, else parts/
        rel = ('parts-%s/%s' % (device, name)) if os.path.isfile(os.path.join(own, name)) else 'parts/' + name
        out.append((rel, os.path.join(assets, rel), 'file'))
    if device != 'rg35xx-plus':
        out.append(('device-%s/package/boot_package.fex' % device,
                    os.path.join(assets, 'device-' + device, 'package', 'boot_package.fex'), 'file'))
        if os.path.isfile(os.path.join(own, 'boot0.img')):
            out.append(('parts-%s/boot0.img' % device, os.path.join(own, 'boot0.img'), 'file'))
        out.append(('device-%s/' % device, os.path.join(assets, 'device-' + device), 'tree'))
    return out


def load_manifest():
    m = {}
    with open(MANIFEST) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            board, key, digest = line.split()
            m.setdefault(board, {})[key] = digest
    return m


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    flags = [a for a in sys.argv[1:] if a.startswith('--')]
    if len(args) != 2:
        sys.exit(__doc__)
    assets, device = args
    rootfs = '--no-rootfs' not in flags
    found = []
    for key, path, kind in inputs(assets, device, rootfs):
        if kind == 'tree' and not os.path.isdir(path) or kind == 'file' and not os.path.isfile(path):
            found.append((key, None))
        else:
            found.append((key, sha256_tree(path) if kind == 'tree' else sha256_file(path)))
    if '--write' in flags:
        for key, digest in found:
            if digest is None:
                sys.exit('missing: %s' % key)
            print('%s %s %s' % (device, key, digest))
        return
    m = load_manifest()
    if device not in m:
        sys.exit('ERROR: %s has no entry in %s; add its pinned inputs first (--write)' % (device, MANIFEST))
    want = m[device]
    bad = 0
    for key, digest in found:
        if key not in want:
            print('ERROR: %s reads %s, which its manifest does not list (a part() fallback it did not pin?)' % (device, key))
            bad = 1
        elif digest is None:
            print('ERROR: %s: %s is missing from %s' % (device, key, assets))
            bad = 1
        elif digest != want[key]:
            print('ERROR: %s: %s does not match the manifest (%s, want %s)' % (device, key, digest[:12], want[key][:12]))
            bad = 1
    used = {k for k, _ in found}
    for key in want:
        if key not in used and not (key == 'muos-p5.img' and not rootfs):
            print('ERROR: %s: manifest pins %s but this asset folder would not use it' % (device, key))
            bad = 1
    if bad:
        sys.exit(1)
    print('  assets: %d inputs for %s match %s' % (len(found), device, os.path.basename(MANIFEST)))


if __name__ == '__main__':
    main()
