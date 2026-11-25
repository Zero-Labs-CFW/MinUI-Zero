#!/usr/bin/env python3
"""Portable policy + ELF fence checks; add --arm64 for the real assembly ABI test."""
import argparse
import importlib.util
import os
from pathlib import Path
import shlex
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser()
p.add_argument('--arm64', action='store_true')
a = p.parse_args()
spec = importlib.util.spec_from_file_location('checker', ROOT/'tools/checkelf.py')
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)
for line in ('1000: mov v0.16b, v1.16b', '1004: mrs x9, fpcr', '1008: str q26, [sp, #448]'):
    assert checker.unexpected_fp(line, [])
    assert not checker.unexpected_fp(line, [(0x1000,0x100c)])
assert checker.unexpected_fp('100c: ldr q0, [sp]', [(0x1000,0x100c)])
assert not checker.unexpected_fp('2000: mrs x5, currentel', [])
print('PASS ELF FP fence: no exception outside exact SHA function ranges')
cc = shlex.split(os.environ.get('CC','cc'))
with tempfile.TemporaryDirectory(prefix='zero-sha-ce-') as d:
    exe = Path(d)/'test'
    subprocess.run([*cc,'-std=gnu11','-O2','-Wall','-Wextra','-Werror','-I',ROOT,
                    ROOT/'test/sha_ce_policy_test.c','-o',exe],check=True)
    subprocess.run([exe],check=True)
    if a.arm64:
        subprocess.run([*cc,'-std=gnu11','-O2','-Wall','-Wextra','-Werror','-I',ROOT,
            ROOT/'test/sha_ce_preserve_test.c',ROOT/'test/sha_ce_preserve_test.S',
            ROOT/'lib/sha256.c',ROOT/'lib/sha256_ce_core.S',ROOT/'lib/sha256_ce_preserve.S',
            '-Wl,-z,noexecstack','-o',exe],check=True)
        subprocess.run([exe],check=True)
