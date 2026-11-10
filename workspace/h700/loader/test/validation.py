#!/usr/bin/env python3
"""Offline Linux lifecycle supplement. All output stays under loader/test/validation-run."""
import hashlib
import argparse
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
OUT = None
FIXTURES = None


def run(command, log, **kwargs):
    line = "+ " + shlex.join(map(str, command)) + "\n"
    print(line, end="", flush=True)
    log.write(line)
    log.flush()
    result = subprocess.run(list(map(str, command)), stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, **kwargs)
    print(result.stdout, end="", flush=True)
    log.write(result.stdout)
    log.flush()
    result.check_returncode()


def hashes():
    files = [p for p in ROOT.rglob("*") if p.is_file()
             and not {"build", "obj", "validation-run", "__pycache__"}.intersection(p.relative_to(ROOT).parts)]
    files += [FIXTURES / name for name in ("pkg/dtb.bin", "pkg/monitor.bin", "bootimg-hdr-plus.bin")]
    files += [FIXTURES / "devices/plus-215203/boot.img"]
    return {str(p): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(files)}


def main():
    global OUT, FIXTURES
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--fixtures', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    OUT, FIXTURES = args.output.resolve(), args.fixtures.resolve()
    if not sys.platform.startswith("linux"):
        raise SystemExit("Linux MAP_FIXED_NOREPLACE required; use the offline Docker command in validation-gaps.md")
    OUT.mkdir(parents=True, exist_ok=True)
    before = hashes()
    with (OUT / "run.log").open("w") as log:
        run(["cc", "--version"], log)
        run([sys.executable, "-I", ROOT / "test/offline.py", "--output", OUT / "existing",
             '--fixtures', FIXTURES, "--bootimg", FIXTURES / "devices/plus-215203/boot.img"], log)
        sources = ["test/offline_lifecycle.c", "monitor.c", "rtc.c", "wdt.c", "fixup.c",
                   "lib/crc32.c", "libdeflate/lib/utils.c", "libdeflate/lib/deflate_decompress.c",
                   "libdeflate/lib/gzip_decompress.c", "libdeflate/lib/x86/cpu_features.c"]
        sources += [str(p.relative_to(ROOT)) for p in sorted((ROOT / "libfdt").glob("*.c"))]
        flags = ["-std=gnu11", "-O1", "-g", "-D__UBOOT__", "-DFREESTANDING", "-DZL_HOST_TEST", "-fno-strict-aliasing",
                 "-fsanitize=address,undefined", "-fno-omit-frame-pointer", "-I" + str(ROOT),
                 "-I" + str(ROOT / "include"), "-I" + str(ROOT / "libfdt")]
        exe = OUT / "test-lifecycle"
        run(["cc", *flags, *(ROOT / name for name in sources), "-o", exe], log)
        env = dict(os.environ, ASAN_OPTIONS="detect_leaks=1", UBSAN_OPTIONS="halt_on_error=1:print_stacktrace=1")
        run([exe, FIXTURES / "pkg/dtb.bin", FIXTURES / "bootimg-hdr-plus.bin",
             FIXTURES / "pkg/monitor.bin", OUT / "existing/kernel.gz"], log, env=env)
        after = hashes()
        if before != after:
            raise RuntimeError("sources/fixtures/sealed loader changed during run; results are not a stable snapshot")
        (OUT / "inputs.sha256.json").write_text(json.dumps(after, indent=2, sort_keys=True) + "\n")
        outputs = {str(p.relative_to(OUT)): hashlib.sha256(p.read_bytes()).hexdigest()
                   for p in OUT.rglob("*") if p.is_file() and p.name not in {"run.log", "artifacts.sha256.json"}}
        (OUT / "artifacts.sha256.json").write_text(json.dumps(outputs, indent=2, sort_keys=True) + "\n")
        print("PASS stable source/fixture/sealed-loader snapshot", flush=True)
        log.write("PASS stable source/fixture/sealed-loader snapshot\n")


if __name__ == "__main__":
    main()
