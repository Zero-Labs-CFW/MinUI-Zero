#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0+
"""Capture-free packaged parser tests; optional read-only archived artifact checks.

python3 -B test/packaged_test.py
python3 -B test/packaged_test.py --packaged /path/to/boards-stage
Add --manifest /path/to/reviewed.json for explicit offline rows (not admission).
"""
import argparse
from dataclasses import replace
import gzip
import hashlib
import importlib.util
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest import mock

LOADER = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('packaged_genprofiles', LOADER / 'tools/genprofiles.py')
gen = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = gen
spec.loader.exec_module(gen)


def put(data, offset, value):
    struct.pack_into('<I', data, offset, value)


def checksum(data, field):
    put(data, field, 0x5f0a6c39)
    put(data, field, sum(struct.unpack('<%dI' % (len(data) // 4), data)) & 0xffffffff)
    return bytes(data)


def package():
    data = bytearray(3584)
    data[:16] = b'sunxi-package\0\0\0'
    put(data, 16, 0x89119800)
    put(data, 32, 4)
    put(data, 36, len(data))
    for i, name in enumerate(('u-boot', 'monitor', 'dtbo', 'dtb')):
        at, offset = 64 + i * 368, 1536 + i * 512
        data[at:at + len(name)] = name.encode()
        put(data, at + 64, offset)
        put(data, at + 68, 512)
        if name in ('u-boot', 'monitor'):
            put(data, offset + 0x2c, 0x4a000000 if name == 'u-boot' else 0x48000000)
    put(data, 1536 + 20, 512)
    data[1536:2048] = checksum(data[1536:2048], 12)
    return checksum(data, 20)


def image():
    data = bytearray((i * 17 + 3) & 255 for i in range(4096))
    data[0x38:0x3c] = b'ARM\x64'
    return bytes(data)


def boot(kernel=None):
    if kernel is None:
        kernel = gzip.compress(image(), mtime=0)
    header = bytearray(2048)
    header[:8] = b'ANDROID!'
    for offset, value in ((8, len(kernel)), (12, 0x40080000), (16, 512),
                          (20, 0x42000000), (36, 2048), (40, 2), (1644, 1660)):
        put(header, offset, value)
    # Real normalized images retain stale appended-DTB metadata; only TOC DTB is used.
    put(header, 1648, 123456)
    return bytes(header) + kernel.ljust((len(kernel) + 2047) // 2048 * 2048, b'\0') + bytes(2048)


def record(row):
    return {'id': row.id, 'board': row.name, 'ram_mib': row.ram_mib,
            'lengths': list(row.lengths), 'sha256': row.digest.hex()}


class PackagedTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / 'stage'
        self.root.mkdir()
        (self.root / 'kernels').mkdir()
        (self.root / 'kernels/test.img.gz').write_bytes(gzip.compress(boot(), mtime=0))
        for directory in gen.PACKAGED_BOARDS.values():
            path = self.root / directory
            path.mkdir()
            (path / 'package.fex').write_bytes(package())
            (path / 'kernel').write_text('test.img.gz\n')
        self.selection = [{'id': 1, 'board': 'plus', 'ram_mib': 1024}]

    def load(self, rows=None):
        return gen.load_packaged(self.root, self.selection if rows is None else rows)

    def public(self, rows):
        path = Path(self.temp.name) / 'public'
        path.mkdir(exist_ok=True)
        (path / 'profiles.json').write_text(json.dumps({'profiles': rows}))
        return mock.patch.object(gen, 'ROOT', path)

    def test_all_board_directories_and_requirement_ram(self):
        rows = [{'id': i, 'board': name, 'ram_mib': 2048 if name == 'rg34xx-sp' else 1024}
                for i, name in enumerate(gen.PACKAGED_BOARDS, 1)]
        parsed = self.load(rows)
        self.assertEqual(len(parsed), 11)
        for actual, expected in zip(parsed, rows):
            self.assertEqual((actual.id, actual.name, actual.ram_mib),
                             (expected['id'], expected['board'], expected['ram_mib']))
            self.assertEqual(actual.folder, gen.PACKAGED_BOARDS[actual.name])
            self.assertEqual((actual.memory_sha, actual.manifest_sha), ('', ''))
            self.assertIn('unmeasured', actual.source)
        self.assertNotEqual(self.load()[0].digest, self.load([dict(self.selection[0], ram_mib=2048)])[0].digest)

    def test_default_reads_manifest_not_cohorts(self):
        rows = [{'id': 9, 'board': 'rg34xx-h', 'ram_mib': 2048}]
        with self.public(rows):
            result = gen.load_packaged(self.root)
        self.assertEqual([(r.id, r.name, r.ram_mib) for r in result], [(9, 'rg34xx-h', 2048)])

    def test_selection_rejections(self):
        invalid = [[], self.selection * 2,
                   [self.selection[0], dict(self.selection[0], id=2)],
                   [dict(self.selection[0], board=name) for name in ('../escape',)],
                   [dict(self.selection[0], board='2024')],
                   [dict(self.selection[0], board='rg35xx-plus')]]
        invalid += [[dict(self.selection[0], id=value)] for value in (True, 0, -1, 1 << 32, '1')]
        invalid += [[dict(self.selection[0], ram_mib=value)] for value in (True, 0, 512, '1024')]
        for rows in invalid:
            with self.subTest(rows=rows), self.assertRaises(ValueError):
                self.load(rows)

    def test_unsafe_kernel_names(self):
        pointer = self.root / 'rg35xx-plus/kernel'
        for name in ('', '.', '..', '../test.img.gz', '/test.img.gz', 'a/b', 'a\\b'):
            pointer.write_text(name)
            with self.subTest(name=name), self.assertRaises(ValueError):
                self.load()

    def test_symlink_escapes(self):
        for relative in ('rg35xx-plus/package.fex', 'rg35xx-plus/kernel', 'kernels/test.img.gz'):
            path = self.root / relative
            data = path.read_bytes()
            outside = Path(self.temp.name) / 'outside'
            outside.write_bytes(data)
            path.unlink()
            path.symlink_to(outside)
            with self.subTest(path=relative), self.assertRaisesRegex(ValueError, 'escapes'):
                self.load()
            path.unlink()
            path.write_bytes(data)

    def test_toc_mutations(self):
        mutations = [('short', lambda b: b[:40], 'TOC'),
                     ('truncated', lambda b: b[:-1], 'bounds')]
        for name, offset, value, reason in (
                ('magic', 0, 0, 'TOC'), ('marker', 16, 0, 'TOC'),
                ('count', 32, 5, 'bounds'), ('declared size', 36, 3580, 'bounds'),
                ('unaligned', 128, 1537, 'span'), ('table overlap', 128, 1024, 'span'),
                ('overflow', 128, 0xfffffe00, 'span'), ('zero size', 132, 0, 'span'),
                ('too long', 132, 4096, 'span'), ('role overlap', 128 + 368, 1536, 'overlapping'),
                ('monitor address', 2048 + 0x2c, 0, 'run address'),
                ('uboot address', 1536 + 0x2c, 0, 'run address'),
                ('uboot length', 1536 + 20, 508, 'checksum/length'),
                ('uboot checksum', 1536 + 12, 0, 'checksum/length')):
            def mutate(b, offset=offset, value=value):
                put(b, offset, value)
                return b
            mutations.append((name, mutate, reason))
        for name, value, reason in (('duplicate', b'monitor\0', 'duplicate'),
                                    ('unknown', b'other\0', 'unknown'),
                                    ('nonascii', b'\xff\0', 'non-ASCII'),
                                    ('unterminated', b'X' * 64, 'unterminated')):
            def mutate(b, value=value):
                b[64:128] = value.ljust(64, b'\0')
                return b
            mutations.append((name, mutate, reason))
        for name, mutate, reason in mutations:
            changed = mutate(bytearray(package()))
            if len(changed) % 4 == 0 and len(changed) >= 64:
                changed = checksum(changed, 20)
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, reason):
                gen.packaged_parts(bytes(changed), boot())
        changed = bytearray(package())
        changed[-1] ^= 1
        with self.assertRaisesRegex(ValueError, 'package checksum'):
            gen.packaged_parts(changed, boot())

    def test_android_mutations(self):
        for offset, value in ((0, 0), (8, 0), (8, (32 << 20) + 1), (12, 0),
                              (16, 0), (16, (1 << 20) + 1), (20, 0), (24, 1),
                              (36, 4096), (40, 1), (1632, 1), (1636, 1), (1644, 0)):
            changed = bytearray(boot())
            put(changed, offset, value)
            with self.subTest(offset=offset, value=value), self.assertRaises(ValueError):
                gen.packaged_parts(package(), changed)
        for changed in (boot()[:2047], boot()[:2048], boot()[:-1], boot() + b'\0'):
            with self.subTest(length=len(changed)), self.assertRaises(ValueError):
                gen.packaged_parts(package(), changed)

    def test_gzip_mutations(self):
        packed = gzip.compress(image(), mtime=0)
        corrupt = bytearray(packed)
        corrupt[-8] ^= 1
        for kernel in (b'not gzip', packed[:-1], bytes(corrupt), packed + b'\0', packed * 2,
                       gzip.compress(b'not an ARM64 image', mtime=0)):
            with self.subTest(kernel=kernel[:16]), self.assertRaises(ValueError):
                gen.packaged_parts(package(), boot(kernel))
        with self.assertRaises(ValueError):
            gen.packaged_gzip(gzip.compress(bytes(100), mtime=0), 99, 'bounded')
        self.assertEqual(gen.packaged_gzip(gzip.compress(bytes(100), mtime=0), 100, 'bounded'), bytes(100))
        outer = self.root / 'kernels/test.img.gz'
        original = outer.read_bytes()
        for data in (original[:-1], original + b'\0', original * 2, b'not gzip'):
            outer.write_bytes(data)
            with self.subTest(outer=data[:16]), self.assertRaises(ValueError):
                self.load()

    def test_subset_by_id_not_order_or_count(self):
        one = self.load()[0]
        two = replace(one, id=2, name='h', ram_mib=2048)
        three = replace(one, id=3, name='pro', ram_mib=2048,
                        parts=one.parts[:5] + (one.parts[5][:-1] + b'X',) + one.parts[6:])
        with self.public([record(three), record(two), record(one)]):
            gen.validate_public([one])
            gen.validate_public([two, one])
            for rows in ([], [one, one], [replace(one, id=99)], [replace(one, name='h')],
                         [replace(one, ram_mib=2048)], [replace(one, parts=one.parts[:-1])]):
                with self.subTest(rows=rows), self.assertRaises(ValueError):
                    gen.validate_public(rows)

    def test_variant_ram_lengths_and_header(self):
        base = self.load()[0]
        variant = replace(base, ram_mib=2048,
                          parts=base.parts[:5] + (base.parts[5][:-1] + b'X',) + base.parts[6:])
        entry = record(base)
        entry['variants'] = [{'sha256': variant.digest.hex(), 'ram_mib': 2048,
                              'boot_header_sha256': hashlib.sha256(variant.parts[5]).hexdigest()}]
        with self.public([entry]):
            gen.validate_public([variant])
        for field, value in (('boot_header_sha256', '0' * 64), ('ram_mib', 1024)):
            changed = json.loads(json.dumps(entry))
            changed['variants'][0][field] = value
            with self.public([changed]), self.assertRaises(ValueError):
                gen.validate_public([variant])
        changed = json.loads(json.dumps(entry))
        del changed['variants'][0]['boot_header_sha256']
        with self.public([changed]), self.assertRaisesRegex(ValueError, 'missing reviewed header'):
            gen.validate_public([variant])
        entry['lengths'][0] += 1
        with self.public([entry]), self.assertRaises(ValueError):
            gen.validate_public([variant])

    def test_ambiguous_public_manifest_rejected(self):
        row = self.load()[0]
        for entries in ([record(row), record(row)],
                        [record(row), dict(record(row), id=2, board='h')]):
            with self.public(entries), self.assertRaisesRegex(ValueError, 'duplicate'):
                gen.validate_public([row])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--packaged', type=Path)
    parser.add_argument('--manifest', type=Path, help='explicit reviewed profiles JSON for offline extraction only')
    args = parser.parse_args()
    if args.manifest and not args.packaged:
        parser.error('--manifest requires --packaged')
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(PackagedTests))
    if not result.wasSuccessful():
        raise SystemExit(1)
    if args.packaged:
        manifest = json.loads(args.manifest.read_text())['profiles'] if args.manifest else None
        rows = gen.load_packaged(args.packaged, manifest)
        if manifest is None:
            gen.validate_public(rows)
        for row in rows:
            print(f'ID {row.id} {row.name}: RAM requirement {row.ram_mib} MiB (NOT measured), '
                  f'lengths {row.lengths}, SHA256 {row.digest.hex()}')
        print('PASS archived packaged extraction; explicit offline rows do not grant admission or qualification')


if __name__ == '__main__':
    main()
