#!/usr/bin/env python3
"""Portable no-device smoke and manifest tests; captures are a separate explicit gate."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile

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
             (0, 'panel_rule', 'constant-boe'), (0, 'qualification', 'qualified')]
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
print('PASS tracked profile manifest + 9 refusal mutations; no external captures or hardware required')
