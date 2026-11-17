#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0+
"""Generate the accidental-mismatch allowlist, not a secure-boot trust anchor.

Transcript (no domain tag): u32le RAM MiB, then u32le length + exact bytes
for TOC header/table, monitor, U-Boot, DTB, DTBO, boot header, gzip, ramdisk.
"""
import argparse
from dataclasses import dataclass
import hashlib
import gzip
import json
from pathlib import Path
import struct
import zlib

ROOT = Path(__file__).resolve().parents[1]
COHORTS = ((1, "plus", "plus-215203"), (2, "h", "h-215206"))
PART_NAMES = ("toc", "monitor", "u-boot", "dtb", "dtbo", "boot-header", "gzip", "ramdisk")
PACKAGED_BOARDS = {name: 'rg35xx-' + name for name in ('plus', 'h', 'pro', 'sp')}
PACKAGED_BOARDS.update({name: name for name in
                       ('rg40xx-h', 'rg40xx-v', 'rgcubexx-h', 'rg28xx-h',
                        'rg34xx-h', 'rg34xx-sp', 'rgsp')})


def require(condition, message):
    if not condition:
        raise ValueError(message)


def u32(data, offset):
    return struct.unpack_from("<I", data, offset)[0]


def span(data, offset, length, label):
    require(0 <= offset <= len(data) and 0 <= length <= len(data) - offset,
            f"{label}: out-of-bounds span")
    return data[offset:offset + length]


@dataclass(frozen=True)
class Cohort:
    id: int
    name: str
    folder: str
    ram_mib: int
    parts: tuple
    package_sha: str
    boot_sha: str
    memory_sha: str
    manifest_sha: str
    source: str

    @property
    def lengths(self):
        return tuple(map(len, self.parts))

    @property
    def digest(self):
        ctx = hashlib.sha256(struct.pack("<I", self.ram_mib))
        for part in self.parts:
            ctx.update(struct.pack("<I", len(part)))
            ctx.update(part)
        return ctx.digest()


def load_cohort(root, ident, name, folder):
    directory = root / "devices" / folder
    manifest_bytes = (directory / "manifest.json").read_bytes()
    manifest = json.loads(manifest_bytes)
    require(manifest["board"] == name, f"{folder}: wrong board")
    blobs = {}
    for filename, record in manifest["files"].items():
        require(Path(filename).name == filename and filename not in (".", ".."),
                f"{folder}: unsafe manifest filename")
        data = (directory / filename).read_bytes()
        require(len(data) == record["bytes"] and hashlib.sha256(data).hexdigest() == record["sha256"],
                f"{folder}/{filename}: manifest size/SHA256 mismatch")
        blobs[filename] = data
    memory = blobs["memory-reg.bin"]
    require(len(memory) == 16, f"{folder}: unsupported memory reg cells")
    base, size = struct.unpack(">QQ", memory)
    require(base == 0x40000000 and size and size % (1 << 20) == 0,
            f"{folder}: unqualified measured RAM range")
    ram_mib = size >> 20
    require(ram_mib == 1024, f"{folder}: measured RAM is not qualified 1024 MiB")
    require(manifest["dram_words"][7] >> 16 == ram_mib,
            f"{folder}: measured RAM differs from recorded DRAM words")

    package = blobs["package.fex"]
    require(len(package) >= 64 and package[:13] == b"sunxi-package", f"{folder}: bad TOC")
    count, total = u32(package, 32), u32(package, 36)
    require(0 < count <= 16 and total == manifest["package_declared_length"] and total <= len(package),
            f"{folder}: bad package count/length")
    table = span(package, 0, 64 + count * 368, "TOC table")
    items, ranges = {}, []
    for index in range(count):
        item = table[64 + index * 368:64 + (index + 1) * 368]
        require(b"\0" in item[:64], f"{folder}: unterminated TOC name")
        role = item[:64].split(b"\0", 1)[0].decode("ascii")
        require(role in PART_NAMES[1:5] and role not in items, f"{folder}: unknown/duplicate role {role}")
        offset, length = u32(item, 64), u32(item, 68)
        require(offset % 512 == 0 and offset >= len(table) and length > 0 and
                offset <= total and length <= total - offset, f"{folder}: bad item span {role}")
        require(all(offset >= end or offset + length <= start for start, end in ranges),
                f"{folder}: overlapping TOC items")
        ranges.append((offset, offset + length))
        items[role] = span(package, offset, length, role)
    require(set(items) == set(PART_NAMES[1:5]), f"{folder}: missing TOC role")
    for role, address in (("monitor", 0x48000000), ("u-boot", 0x4a000000)):
        require(len(items[role]) >= 0x30 and u32(items[role], 0x2c) == address,
                f"{folder}: wrong {role} run address")

    boot = blobs["boot.img"]
    header = span(boot, 0, 2048, "boot header")
    require(header == blobs["boot-header.bin"] and header[:8] == b"ANDROID!",
            f"{folder}: boot header mismatch")
    kernel_size, kernel_addr, rd_size, rd_addr, second_size = struct.unpack_from("<5I", header, 8)
    require(u32(header, 36) == 2048 and u32(header, 40) == 2 and kernel_addr == 0x40080000 and
            rd_addr == 0x42000000 and second_size == 0 and 0 < kernel_size <= 32 << 20 and
            0 < rd_size <= 1 << 20, f"{folder}: unsupported Android layout")
    require(struct.unpack_from("<IQ", header, 1632) == (0, 0) and u32(header, 1644) == 1660,
            f"{folder}: unsupported recovery payload or header size")
    # v2 declares an appended DTB, but this loader consumes the TOC DTB instead.
    kernel = span(boot, 2048, kernel_size, "gzip")
    require(kernel[:2] == b"\x1f\x8b", f"{folder}: kernel is not gzip")
    rd_offset = 2048 + ((kernel_size + 2047) // 2048) * 2048
    ramdisk = span(boot, rd_offset, rd_size, "ramdisk")
    parts = (table, items["monitor"], items["u-boot"], items["dtb"], items["dtbo"], header, kernel, ramdisk)
    return Cohort(ident, name, folder, ram_mib, parts, hashlib.sha256(package).hexdigest(),
                  hashlib.sha256(boot).hexdigest(), hashlib.sha256(memory).hexdigest(),
                  hashlib.sha256(manifest_bytes).hexdigest(), manifest["source"])


def load_profiles(root):
    return tuple(load_cohort(root, *cohort) for cohort in COHORTS)


def packaged_path(root, *names):
    path = root.joinpath(*names).resolve()
    require(path.is_relative_to(root), 'packaged path escapes artifact root')
    return path


def packaged_gzip(data, limit, label):
    inflater = zlib.decompressobj(16 + zlib.MAX_WBITS)
    try:
        inflated = inflater.decompress(data, limit + 1)
    except zlib.error as error:
        raise ValueError(f'{label}: invalid gzip') from error
    require(len(inflated) <= limit and inflater.eof and not inflater.unused_data and
            not inflater.unconsumed_tail, f'{label}: oversized, truncated or trailing gzip')
    return inflated


def packaged_checksum(data, field):
    require(len(data) % 4 == 0 and field + 4 <= len(data), 'unaligned checksum block')
    return (sum(struct.unpack('<%dI' % (len(data) // 4), data)) - u32(data, field) + 0x5f0a6c39) & 0xffffffff


def packaged_parts(package, boot):
    require(len(package) >= 64 and len(package) <= 32 << 20 and
            package[:16] == b'sunxi-package\0\0\0' and u32(package, 16) == 0x89119800,
            'bad packaged TOC')
    count, total = u32(package, 32), u32(package, 36)
    require(count == 4 and total == len(package), 'bad packaged TOC bounds')
    require(packaged_checksum(package, 20) == u32(package, 20), 'bad package checksum')
    table = span(package, 0, 64 + count * 368, 'packaged table')
    items, ranges = {}, []
    for i in range(count):
        item = table[64 + i * 368:64 + (i + 1) * 368]
        require(b'\0' in item[:64], 'unterminated packaged role')
        try:
            role = item[:64].split(b'\0', 1)[0].decode('ascii')
        except UnicodeDecodeError as error:
            raise ValueError('non-ASCII packaged role') from error
        require(role in PART_NAMES[1:5] and role not in items, 'duplicate/unknown packaged role')
        offset, length = u32(item, 64), u32(item, 68)
        require(offset >= len(table) and offset % 512 == 0 and length > 0 and
                offset <= total and length <= total - offset, 'bad packaged role span')
        require(all(offset >= end or offset + length <= start for start, end in ranges),
                'overlapping packaged roles')
        ranges.append((offset, offset + length))
        items[role] = span(package, offset, length, role)
    require(set(items) == set(PART_NAMES[1:5]), 'missing packaged role')
    for role, address in (('monitor', 0x48000000), ('u-boot', 0x4a000000)):
        require(len(items[role]) >= 0x30 and u32(items[role], 0x2c) == address,
                f'wrong packaged {role} run address')
    ub = items['u-boot']
    require(u32(ub, 20) == len(ub) and packaged_checksum(ub, 12) == u32(ub, 12),
            'bad packaged U-Boot checksum/length')

    header = span(boot, 0, 2048, 'packaged header')
    ks, ka, rs, ra, second = struct.unpack_from('<5I', header, 8)
    require(header[:8] == b'ANDROID!' and u32(header, 36) == 2048 and
            u32(header, 40) == 2 and ka == 0x40080000 and ra == 0x42000000 and
            second == 0 and 0 < ks <= 32 << 20 and 0 < rs <= 1 << 20,
            'bad packaged Android v2 layout')
    require(struct.unpack_from('<IQ', header, 1632) == (0, 0) and u32(header, 1644) == 1660,
            'unsupported packaged recovery payload or header size')
    rd_offset = 2048 + ((ks + 2047) // 2048) * 2048
    require(len(boot) == rd_offset + ((rs + 2047) // 2048) * 2048,
            'bad packaged Android span/padding')
    kernel = span(boot, 2048, ks, 'packaged gzip')
    image = packaged_gzip(kernel, 32 << 20, 'packaged kernel')
    require(len(image) >= 64 and image[0x38:0x3c] == b'ARM\x64', 'not a packaged ARM64 Image')
    ramdisk = span(boot, rd_offset, rs, 'packaged ramdisk')
    # Match load_cohort: appended-DTB metadata is hashed, but only the TOC DTB is consumed.
    return (table, items['monitor'], items['u-boot'], items['dtb'], items['dtbo'],
            header, kernel, ramdisk)


def load_packaged(root, manifest_rows=None):
    """Extract reviewed selections (default: public manifest), without granting admission.

    RAM is the input requirement, not a unit measurement. Explicit offline rows
    need not be admitted profiles; validate_public is a separate check.
    """
    root = Path(root).resolve()
    if manifest_rows is None:
        manifest_rows = json.loads((ROOT / 'profiles.json').read_text())['profiles']
    rows, seen_ids, seen_boards = [], set(), set()
    for item in manifest_rows:
        ident, name, ram_mib = item['id'], item['board'], item['ram_mib']
        require(type(ident) is int and 0 < ident <= 0xffffffff and ident not in seen_ids,
                'duplicate/invalid packaged profile ID')
        require(name in PACKAGED_BOARDS and name not in seen_boards, 'duplicate/unknown packaged board')
        require(type(ram_mib) is int and ram_mib in (1024, 2048), 'unsupported packaged RAM requirement')
        seen_ids.add(ident)
        seen_boards.add(name)
        directory = PACKAGED_BOARDS[name]
        package = packaged_path(root, directory, 'package.fex').read_bytes()
        kernel_name = packaged_path(root, directory, 'kernel').read_text().strip()
        require(Path(kernel_name).name == kernel_name and kernel_name not in ('', '.', '..') and
                '\\' not in kernel_name, 'unsafe kernel name')
        boot = packaged_gzip(packaged_path(root, 'kernels', kernel_name).read_bytes(),
                             2048 + (32 << 20) + (1 << 20), 'packaged boot')
        parts = packaged_parts(package, boot)
        rows.append(Cohort(ident, name, directory, ram_mib, parts,
                           hashlib.sha256(package).hexdigest(), hashlib.sha256(boot).hexdigest(),
                           '', '', 'packaged-artifact-only; unit RAM unmeasured'))
    require(rows, 'empty packaged profile selection')
    return tuple(rows)


def validate_public(rows):
    public = json.loads((ROOT / 'profiles.json').read_text())['profiles']
    by_id = {}
    hashes = set()
    for item in public:
        require(type(item['id']) is int and item['id'] not in by_id, 'duplicate/invalid public profile ID')
        by_id[item['id']] = item
        for variant in [item] + item.get('variants', []):
            require(variant['sha256'] not in hashes, 'duplicate public transcript identity')
            hashes.add(variant['sha256'])
    seen = set()
    for row in rows:
        require(type(row.id) is int and row.id not in seen, 'duplicate/invalid supplied profile ID')
        seen.add(row.id)
        require(row.id in by_id, 'unknown supplied profile ID')
        item = by_id[row.id]
        digest = row.digest.hex()
        matches = [variant for variant in [item] + item.get('variants', []) if variant['sha256'] == digest]
        require(len(matches) == 1 and row.name == item['board'] and
                row.lengths == tuple(item['lengths']) and
                row.ram_mib == matches[0].get('ram_mib', item['ram_mib']),
                'capture differs from reviewed public profile')
        require(matches[0] is item or 'boot_header_sha256' in matches[0],
                'variant missing reviewed header identity')
        if 'boot_header_sha256' in matches[0]:
            require(hashlib.sha256(row.parts[5]).hexdigest() == matches[0]['boot_header_sha256'],
                    'variant header differs from reviewed identity')
    require(seen, 'empty supplied profile subset')


def render(profiles):
    lines = ["/* Generated by tools/genprofiles.py; do not edit.",
             " * Accidental-mismatch allowlist only, NOT secure boot.",
             " * No domain tag: u32le RAM MiB, then eight (u32le length, bytes) parts.",
             " * Order: TOC header/table, monitor, U-Boot, DTB, DTBO, 2048-byte boot header, gzip, ramdisk.",
             " * Android v2 appended-DTB metadata is hashed in the header; only the TOC DTB is consumed."]
    for row in profiles:
        lines += [f" * ID {row.id}: devices/{row.folder}, source {row.source}, measured RAM {row.ram_mib} MiB",
                  f" *   manifest SHA256 {row.manifest_sha}", f" *   memory-reg SHA256 {row.memory_sha}",
                  f" *   package SHA256 {row.package_sha}", f" *   boot.img SHA256 {row.boot_sha}",
                  f" *   transcript SHA256 {row.digest.hex()}"]
    lines += [" */", "static const struct {", "    unsigned int id, ram_mib, lengths[8];",
              "    uint8_t hash[32];", "} profiles[] = {"]
    for row in profiles:
        lines += [f"    {{ {row.id}, {row.ram_mib}, {{ " + ", ".join(map(str, row.lengths)) + " },", "      {"]
        for start in range(0, 32, 8):
            lines.append("        " + ", ".join(f"0x{b:02x}" for b in row.digest[start:start + 8]) + ",")
        lines += ["      } },"]
    return "\n".join(lines + ["};", ""])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    inputs = parser.add_mutually_exclusive_group(required=True)
    inputs.add_argument("--fixtures", type=Path, help="saved cohort root; never a device")
    inputs.add_argument("--packaged", type=Path, help="boards-stage artifact compatibility; NOT measured unit RAM")
    args = parser.parse_args()
    rows = load_profiles(args.fixtures.resolve()) if args.fixtures else load_packaged(args.packaged.resolve())
    validate_public(rows)
    for row in rows:
        ram_kind = 'measured RAM' if args.fixtures else 'required RAM (not measured)'
        print(f"ID {row.id} {row.name}: {ram_kind} {row.ram_mib} MiB, lengths {row.lengths}, SHA256 {row.digest.hex()}")
    print("PASS supplied subset matches reviewed public identities; missing profiles are not verified; no allowlist writes")


if __name__ == "__main__":
    main()
