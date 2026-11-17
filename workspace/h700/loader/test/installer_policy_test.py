#!/usr/bin/env python3
"""Execute only the shipping installer's pure board gate; never its card I/O."""
import json
from pathlib import Path
import subprocess

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
