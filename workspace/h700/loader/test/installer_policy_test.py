#!/usr/bin/env python3
"""Execute only the shipping installer's pure board gate; never its card I/O."""
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT.parent / 'spl/zero-install.sh').read_text()
start = source.index('stage2_board_ok() {\n')
end = source.index('\n}\n', start) + 3
function = source[start:end]
rows = json.loads((ROOT / 'profiles.json').read_text())['profiles']
types = {row['board']: set(row['dram_types']) for row in rows}
types['h'] = {8}  # Preserve the existing H LPDDR3 refusal, not a measured configuration.
types['2024'] = types['plus']
count = 0
for board in [*types, 'unknown', '', 'plus extra']:
    for kind in ('', '0', '7', '8', '9'):
        for trial in ('', '0', '1'):
            expected = kind.isdigit() and int(kind) in types.get(board, set()) and (board == 'plus' or trial == '1')
            result = subprocess.run(['sh', '-c', function + '\nZERO_STAGE2_TRIAL=$3; stage2_board_ok "$1" "$2"',
                                     'installer-policy', board, kind, trial])
            assert (result.returncode == 0) == bool(expected), (board, kind, trial)
            count += 1
print(f'PASS shipping installer board/type/trial gate: {count} cases; no device code executed')

start = source.index('stage2_consumer_ok() {\n')
end = source.index('\n}\n', start) + 3
function = source[start:end]
with tempfile.TemporaryDirectory(prefix='zero-installer-consumer-') as directory:
    root = Path(directory)
    ack, health, identity = (root / name for name in ('ack', 'health', 'build-id'))
    ack.write_text('#!/bin/sh\necho zero-stage2-health-v1\n')
    identity.write_text('a' * 64 + '\n')
    cases = [('a' * 64, True), ('b' * 64, False), (None, False), ('', False), ('g' * 64, False)]
    for value, accepted in cases:
        reply = 'exit 2' if value is None else "printf '%s\\n' '" + value + "'"
        health.write_text('#!/bin/sh\ncase "$1" in\n--contract) echo zero-stage2-health-v1;;\n'
                          '--build-id) ' + reply + ';;\n*) exit 2;;\nesac\n')
        health.chmod(0o700)
        result = subprocess.run(['sh', '-c', function + '\nstage2_consumer_ok "$1" "$2" "$3"',
                                 'consumer-policy', ack, health, identity])
        assert (result.returncode == 0) == accepted, (value, result.returncode)
print(f'PASS shipping consumer build-cohort gate: {len(cases)} matching/stale/legacy/malformed cases')
