#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0+
"""Test production profile.c + lib/sha256.c, without devices or build-tree writes.

python3 -B test/profile_test.py
python3 -B test/profile_test.py --docker --binary
The latter also executes zero-loader.bin's actual preflight on Linux AArch64.
Build products live in an automatically deleted temporary directory only.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shlex
import struct
import subprocess
import sys
import tempfile
from unittest import mock

LOADER = Path(__file__).resolve().parents[1]
ROOT = LOADER.parent


def generator():
    spec = importlib.util.spec_from_file_location("genprofiles", LOADER / "tools/genprofiles.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def generator_negative_tests(gen):
    directory = ROOT / "devices/plus-215203"
    read_bytes = Path.read_bytes
    original = {p.name: read_bytes(p) for p in directory.iterdir() if p.is_file()}
    mutations = []
    memory = original["memory-reg.bin"]
    mutations += [("memory-reg.bin", bytes(16), True, "RAM"),
                  ("memory-reg.bin", struct.pack(">QQ", 0x40000000, 512 << 20), True, "RAM"),
                  ("memory-reg.bin", memory[:8], True, "memory reg"),
                  ("memory-reg.bin", memory[:-1] + bytes([memory[-1] ^ 1]), False, "manifest")]
    package = bytearray(original["package.fex"])
    package[64+368:64+368+64] = package[64:64+64]
    mutations.append(("package.fex", bytes(package), True, "duplicate"))
    package = bytearray(original["package.fex"])
    struct.pack_into("<I", package, 64+64, 0xfffffe00)
    mutations.append(("package.fex", bytes(package), True, "span"))
    package = bytearray(original["package.fex"])
    package[64:128] = b"X" * 64
    mutations.append(("package.fex", bytes(package), True, "unterminated"))
    mutations.append(("boot.img", original["boot.img"][:2048], True, "span"))
    for filename, changed, update_manifest, reason in mutations:
        replacements = {filename: changed}
        if update_manifest:
            manifest = json.loads(original["manifest.json"])
            manifest["files"][filename] = {"bytes": len(changed), "sha256": hashlib.sha256(changed).hexdigest()}
            replacements["manifest.json"] = json.dumps(manifest).encode()

        def patched_read(path):
            if path.parent == directory and path.name in replacements:
                return replacements[path.name]
            return read_bytes(path)

        with mock.patch.object(Path, "read_bytes", patched_read):
            try:
                gen.load_cohort(ROOT, 1, "plus", "plus-215203")
            except ValueError as error:
                if reason not in str(error):
                    raise AssertionError(f"wrong rejection for {filename}: {error}") from error
            else:
                raise AssertionError(f"generator accepted bad {filename}: {reason}")
    print(f"PASS generator negative fixtures: {len(mutations)} (in-memory only)", flush=True)


def sha_vectors():
    known = (
        (b"", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
        (b"abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
        (b"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
         "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"),
        (b"a" * 1000000, "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"),
    )
    result = []
    for data, digest in known:
        if hashlib.sha256(data).hexdigest() != digest:
            raise AssertionError("known-answer fixture typo")
        for chunk in ((65536,) if len(data) > 1000 else (1, 7, 63, 64, 65, 4096)):
            result.append((data, chunk, bytes.fromhex(digest)))
    for size in (1, 2, 54, 55, 56, 57, 63, 64, 65, 119, 120, 121, 127, 128, 129, 255, 256, 257, 1024):
        data = bytes((i*73+19) & 255 for i in range(size))
        for chunk in (1, 7, 63, 64, 65, 4096):
            result.append((data, chunk, hashlib.sha256(data).digest()))
    return result


def protocol(rows):
    vectors = sha_vectors()
    output = bytearray(struct.pack("<I", len(vectors)))
    for data, chunk, digest in vectors:
        output += struct.pack("<II", len(data), chunk) + data + digest
    for row in rows:
        output += struct.pack("<II", row.id, row.ram_mib)
        for part in row.parts:
            output += struct.pack("<I", len(part)) + part
    return output


def snapshot(binary, artifacts):
    names = ("profile.c", "profile.h", "zero_params.h", "profiles.inc", "lib/sha256.c", "lib/sha256.h",
             "tools/genprofiles.py", "test/profile_test.py", "test/profile_host.c")
    paths = [LOADER / name for name in names]
    result = {str(p.relative_to(LOADER)): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
    if binary:
        for name in ('zero-loader.bin', 'zero-loader.elf'):
            result[name] = hashlib.sha256((artifacts / name).read_bytes()).hexdigest()
    return result


def binary_bss(artifacts):
    elf = (artifacts / "zero-loader.elf").read_bytes()
    image = (artifacts / "zero-loader.bin").read_bytes()
    if elf[:6] != b"\x7fELF\x02\x01" or struct.unpack_from("<H", elf, 18)[0] != 183:
        raise AssertionError("expected little-endian AArch64 ELF64")
    offset = struct.unpack_from("<Q", elf, 40)[0]
    stride, count, strings_index = struct.unpack_from("<HHH", elf, 58)
    if stride != 64 or not 0 < count <= 256 or strings_index >= count or offset + count*stride > len(elf):
        raise AssertionError("unsupported ELF section table")
    sections = [struct.unpack_from("<IIQQQQIIQQ", elf, offset+i*stride) for i in range(count)]
    strings = sections[strings_index]
    names = elf[strings[4]:strings[4]+strings[5]]
    bss = []
    for name, kind, flags, addr, start, size, *_ in sections:
        label = names[name:].split(b"\0", 1)[0]
        if label == b".bss":
            if kind != 8:
                raise AssertionError("BSS is not NOBITS")
            bss.append((addr, size))
        if flags & 2 and kind != 8 and size:
            # The packer intentionally replaces header fields; all executable/data bytes must agree.
            skip = max(0, 0x4c000040 - addr)
            if skip >= size:
                continue
            img_offset = addr + skip - 0x4c000000
            expected = elf[start+skip:start+size]
            if img_offset < 64 or image[img_offset:img_offset+len(expected)] != expected:
                raise AssertionError(f"binary/ELF bytes differ in {label!r}")
    if len(bss) != 1 or not (0x4c000040 <= bss[0][0] < bss[0][0]+bss[0][1] <= 0x4c100000):
        raise AssertionError("invalid loader BSS range")
    print(f"PASS actual binary/ELF allocated bytes; BSS {bss[0][0]:#x}+{bss[0][1]:#x}", flush=True)
    return bss[0]


def main():
    global ROOT
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--fixtures', type=Path, required=True)
    parser.add_argument('--artifacts', type=Path)
    parser.add_argument("--docker", action="store_true", help="run in existing zero-h700-build, offline/read-only")
    parser.add_argument("--binary", action="store_true", help="also execute actual loader binary (Linux AArch64)")
    parser.add_argument("--cc", default=os.environ.get("CC", "cc"))
    args = parser.parse_args()
    if args.docker:
        command = ["docker", "run", "--rm", "--network", "none", "--read-only", "--cap-drop", "ALL",
                   "--security-opt", "no-new-privileges", "--tmpfs", "/tmp:rw,exec,size=256m",
                   "-v", f"{LOADER}:/work:ro", '-v', f'{args.fixtures.resolve()}:/fixtures:ro',
                   "-w", "/work", "zero-h700-build",
                   "python3", "-B", "test/profile_test.py", '--fixtures', '/fixtures']
        if args.binary:
            parser.error('use explicit offline Docker invocation with --artifacts for binary tests')
        print("+ " + shlex.join(command), flush=True)
        subprocess.run(command, check=True)
        return
    ROOT = args.fixtures.resolve()
    gen = generator()
    if args.binary and args.artifacts is None:
        parser.error('--binary requires --artifacts containing the sealed bin and ELF')
    artifacts = args.artifacts.resolve() if args.artifacts else None
    before = snapshot(args.binary, artifacts)
    rows = gen.load_profiles(ROOT)
    gen.validate_public(rows)
    subprocess.run([sys.executable, '-I', LOADER / 'tools/profiles.py', '--check'], check=True)
    print("PASS all cohort manifest size/SHA256 checks; measured RAM; deterministic profiles.inc", flush=True)
    generator_negative_tests(gen)
    with tempfile.TemporaryDirectory(prefix="zero-profile-") as temporary:
        exe = Path(temporary) / "profile-test"
        command = [*shlex.split(args.cc), "-std=gnu11", "-O2", "-g", "-Wall", "-Wextra", "-Werror",
                   "-fno-strict-aliasing", "-fno-omit-frame-pointer", "-fsanitize=address,undefined",
                   "-U__weak",
                   "-I", str(LOADER), str(LOADER / "test/profile_host.c"), str(LOADER / "profile.c"),
                   str(LOADER / "lib/sha256.c"), "-o", str(exe)]
        print("+ " + shlex.join(command), flush=True)
        subprocess.run(command, check=True)
        command = [str(exe)]
        if args.binary:
            command += [str(artifacts / "zero-loader.bin"), *(hex(n) for n in binary_bss(artifacts))]
            print("Actual image SHA256 " + before["zero-loader.bin"], flush=True)
        print("+ " + shlex.join(command), flush=True)
        leaks = 0 if sys.platform == "darwin" else 1
        env = dict(os.environ, ASAN_OPTIONS=f"detect_leaks={leaks}:halt_on_error=1",
                   UBSAN_OPTIONS="halt_on_error=1:print_stacktrace=1")
        subprocess.run(command, input=protocol(rows), env=env, check=True)
    if snapshot(args.binary, artifacts) != before:
        raise AssertionError("tested sources/image changed during run; rerun on a stable snapshot")
    print("PASS stable source" + ("/actual-image" if args.binary else "") + " snapshot; ASan/UBSan clean", flush=True)
    print("No device, PMIC, ledger, shipping-file, or loader-build writes. Not a hardware/cache qualification.")


if __name__ == "__main__":
    main()
