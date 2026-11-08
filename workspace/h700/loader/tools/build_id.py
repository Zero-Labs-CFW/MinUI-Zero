#!/usr/bin/env python3
"""Bind handoff metadata to the compiled source/recipes, not a circular image hash."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def generate():
    files = [p for p in ROOT.rglob('*') if p.is_file() and
             not {'obj', 'build', '__pycache__'}.intersection(p.relative_to(ROOT).parts) and
             (p.suffix in ('.c', '.h', '.S', '.ld', '.inc', '.json', '.py', '.sh') or p.name in ('Makefile', 'Dockerfile'))]
    source = {p.relative_to(ROOT).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(files)}
    encoded = json.dumps(source, sort_keys=True, separators=(',', ':')).encode()
    digest = hashlib.sha256(encoded).digest()
    out = ROOT / 'obj'
    out.mkdir(exist_ok=True)
    header = '#define ZL_BUILD_ID_BYTES { ' + ', '.join('0x%02x' % b for b in digest) + ' }\n'
    for name, data in [('build_id.h', header), ('build-id', digest.hex() + '\n'),
                       ('sources.json', json.dumps(source, indent=2, sort_keys=True) + '\n')]:
        path = out / name
        if not path.exists() or path.read_text() != data:
            path.write_text(data)


if __name__ == '__main__':
    generate()
