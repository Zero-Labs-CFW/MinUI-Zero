#!/usr/bin/env python3
"""Portable no-device smoke and manifest tests; captures are a separate explicit gate."""
import copy
import importlib.util
import json
import os
import random
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import zlib

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('profiles', ROOT / 'tools/profiles.py')
profiles = importlib.util.module_from_spec(spec)
spec.loader.exec_module(profiles)
subprocess.run([sys.executable, '-I', ROOT / 'tools/profiles.py', '--check'], check=True)
original = json.loads((ROOT / 'profiles.json').read_text())
with tempfile.TemporaryDirectory(prefix='zero-loader-unit-') as directory:
    out = Path(directory)
    cases = [(0, 'id', 3), (1, 'id', 1), (0, 'ram_mib', 2048), (0, 'board', 'rgcubexx'),
             (0, 'sha256', 'x'*64), (0, 'lengths', [1]*7), (0, 'lengths', [True]*8),
             (0, 'panel_rule', 'constant-boe'), (0, 'qualification', 'qualified'),
             (1, 'variants', [{'name': 'x', 'sha256': original['profiles'][0]['sha256'], 'boot_header_sha256': '0'*64}]),
             (1, 'variants', [{'name': '../x', 'sha256': '0'*64, 'boot_header_sha256': '0'*64}]),
             (1, 'variants', [{'name': 'x', 'sha256': '0'*64, 'boot_header_sha256': 'bad'}])]
    for index, field, value in cases:
        data = copy.deepcopy(original)
        data['profiles'][index][field] = value
        path = out / 'bad.json'
        path.write_text(json.dumps(data))
        try:
            profiles.load(path)
        except ValueError:
            pass
        else:
            raise AssertionError((index, field, value))
    cc = shlex.split(os.environ.get('CC', 'cc'))
    binary = out / 'sha-smoke'
    subprocess.run([*cc, '-std=gnu11', '-O1', '-g', '-Wall', '-Wextra', '-Werror', '-U__weak',
                    '-fsanitize=address,undefined', '-fno-omit-frame-pointer', '-I', ROOT,
                    ROOT / 'test/sha_smoke.c', ROOT / 'profile.c', ROOT / 'lib/sha256.c',
                    '-o', binary], check=True)
    env = dict(os.environ, ASAN_OPTIONS='detect_leaks=' + ('0' if sys.platform == 'darwin' else '1') + ':halt_on_error=1',
               UBSAN_OPTIONS='halt_on_error=1')
    subprocess.run([binary], check=True, env=env)
    binary = out / 'panel-policies'
    subprocess.run([*cc, '-std=gnu11', '-O1', '-g', '-Wall', '-Wextra', '-Werror', '-DZL_HOST_TEST',
                    '-fsanitize=address,undefined', '-fno-omit-frame-pointer', '-I', ROOT,
                    ROOT / 'test/offline_panel.c', ROOT / 'test/offline_soc.c', ROOT / 'rtc.c',
                    '-o', binary], check=True)
    subprocess.run([binary], check=True, env=env)
    binary = out / 'gzip'
    sources = ['test/offline_gunzip.c', 'gunzip.c', 'lib/crc32.c', 'libdeflate/lib/utils.c',
               'libdeflate/lib/deflate_decompress.c', 'libdeflate/lib/gzip_decompress.c',
               'libdeflate/lib/x86/cpu_features.c']
    subprocess.run([*cc, '-std=gnu11', '-O1', '-g', '-DFREESTANDING', '-DZL_HOST_TEST',
                    '-fno-strict-aliasing', '-fsanitize=address,undefined', '-fno-omit-frame-pointer',
                    '-I', ROOT, '-I', ROOT / 'include',
                    *(ROOT / name for name in sources), '-o', binary], check=True)
    rng = random.Random(700)
    for level, strategy in [(0, zlib.Z_DEFAULT_STRATEGY), (6, zlib.Z_DEFAULT_STRATEGY), (6, zlib.Z_FIXED)]:
        data = bytearray(bytes(rng.randrange(256) for _ in range(1024)) * 16)
        data[56:60] = b'ARM\x64'
        compressor = zlib.compressobj(level, zlib.DEFLATED, 31, strategy=strategy)
        gz = compressor.compress(data) + compressor.flush()
        (out / 'Image').write_bytes(data)
        (out / 'kernel.gz').write_bytes(gz)
        subprocess.run([binary, out / 'kernel.gz', out / 'Image'], check=True, env=env)
    binary = out / 'memory-layout'
    subprocess.run([*cc, '-std=gnu11', '-O1', '-g', '-Wall', '-Wextra', '-Werror', '-DZL_HOST_TEST',
                    '-fsanitize=address,undefined', '-fno-omit-frame-pointer', '-I', ROOT,
                    ROOT / 'test/memory_layout_test.c', '-o', binary], check=True)
    subprocess.run([binary], check=True, env=env)
    binary = out / 'display-contract'
    subprocess.run([*cc, '-std=gnu11', '-O1', '-g', '-Wall', '-Wextra', '-Werror',
                    '-fsanitize=address,undefined', '-fno-omit-frame-pointer', '-I', ROOT,
                    ROOT / 'test/display_contract_test.c', '-o', binary], check=True)
    subprocess.run([binary], check=True, env=env)
print(f'PASS tracked profile manifest + {len(cases)} refusal mutations; no external captures or hardware required')
