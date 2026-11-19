#!/usr/bin/env python3
"""Use the production identity generator on a small isolated source tree."""
import importlib.util
import json
from pathlib import Path
import tempfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('loader_build_id', ROOT / 'tools/build_id.py')
identity = importlib.util.module_from_spec(spec)
spec.loader.exec_module(identity)
with tempfile.TemporaryDirectory(prefix='zero-build-id-') as directory:
    root = Path(directory)
    identity.ROOT = root / 'loader'
    identity.ROOT.mkdir()
    health = root / 'boot-health'
    health.mkdir()
    (identity.ROOT / 'main.c').write_text('loader fixture\n')
    names = ('boot-health.c', 'boot_health.c', 'boot_health.h')
    for name in names:
        (health / name).write_text(name + '\n')

    def generate():
        identity.generate()
        return (identity.ROOT / 'obj/build-id').read_text()

    previous = generate()
    assert generate() == previous
    source = json.loads((identity.ROOT / 'obj/sources.json').read_text())
    assert set(source) == {'main.c'} | {'../boot-health/' + name for name in names}
    for name in names:
        path = health / name
        path.write_text(path.read_text() + 'changed\n')
        current = generate()
        assert current != previous, name
        previous = current
    (identity.ROOT / 'obj/generated.c').write_text('not an input\n')
    assert generate() == previous
print('PASS loader identity binds every health production source and excludes generated outputs')
