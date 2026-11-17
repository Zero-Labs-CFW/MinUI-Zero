#!/usr/bin/env python3
"""Exercise generated family policy without admitting synthetic firmware identities."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('profiles', ROOT / 'tools/profiles.py')
profiles = importlib.util.module_from_spec(spec)
spec.loader.exec_module(profiles)

legacy = json.loads((ROOT / 'profiles.json').read_text())
family = {'version': 2, 'profiles': []}
for ident, board in profiles.BOARDS.items():
    row = copy.deepcopy(legacy['profiles'][0])
    row.update(id=ident, board=board, sha256=f'{ident:064x}',
               qualification='source-backed', dram_types=[7 if ident % 2 else 8],
               ram_mib=2048 if ident == 10 else 1024,
               panel_rule=list(profiles.PANEL_RULES)[(ident - 1) % 4],
               display=dict(zip(profiles.DISPLAY_KEYS, (720, 480, 640, 480, 320, 240))))
    row.pop('variants', None)
    family['profiles'].append(row)

with tempfile.TemporaryDirectory(prefix='zero-profile-policy-') as directory:
    out = Path(directory)
    path = out / 'manifest.json'
    path.write_text(json.dumps(family))
    rows = profiles.load(path)
    (out / 'profile_policy.inc').write_text(profiles.render_policy(rows))
    for name in ('profile_policy.h', 'panel_policy.h', 'display_contract.h'):
        (out / name).write_bytes((ROOT / name).read_bytes())
    checks = []
    for row in rows:
        ident, ram, dtype = row['id'], row['ram_mib'], row['dram_types'][0]
        checks += [f'assert(zero_profile_memory({ident}, {ram}, {dtype}));',
                   f'assert(!zero_profile_memory({ident}, {ram}, {15 - dtype}));',
                   f'assert(!zero_profile_memory({ident}, {3072 - ram}, {dtype}));',
                   f'assert(zero_profile_policy({ident})->panel_rule == {profiles.PANEL_RULES[row["panel_rule"]]});',
                   f'assert(zero_profile_policy({ident})->display.frame_width == 320);',
                   f'assert(zero_display_profile({ident}, &display));',
                   'assert(!zero_display_v1_compatible(&display));',
                   f'assert(zl_panel_rule_for_profile({ident}) == rules[{(ident - 1) % 4}]);']
    checks += ['assert(!zero_profile_policy(0));', 'assert(!zero_profile_policy(255));',
               'assert(!zero_profile_memory(1, 0, 7));', 'assert(!zero_profile_memory(1, 1024, 32));']
    (out / 'test.c').write_text('#include <assert.h>\n#include "display_contract.h"\n#include "panel_policy.h"\nint main(void) {\n'
                               'struct zero_display_contract display;\n'
                               'const enum zl_panel_rule rules[] = {ZL_PANEL_STRAP_PULL, ZL_PANEL_STRAP_UNCHANGED, ZL_PANEL_OLD, ZL_PANEL_BOE};\n' +
                               '\n'.join(checks) + '\nreturn 0;\n}\n')
    cc = shlex.split(os.environ.get('CC', 'cc'))
    subprocess.run([*cc, '-std=c11', '-Wall', '-Wextra', '-Werror', '-fsanitize=address,undefined',
                    out / 'test.c', '-o', out / 'test'], check=True)
    subprocess.run([out / 'test'], check=True)

    mutations = [lambda d: d.update(version=True),
                 lambda d: d['profiles'][0].pop('display'),
                 lambda d: d['profiles'][0].pop('dram_types'),
                 lambda d: d['profiles'][0].update(dram_types=[7, 7]),
                 lambda d: d['profiles'][0].update(dram_types=[True]),
                 lambda d: d['profiles'][0].update(ram_mib=4096),
                 lambda d: d['profiles'][0]['display'].update(frame_width=0),
                 lambda d: d['profiles'][0]['display'].update(manager_height=4097),
                 lambda d: d['profiles'][0]['display'].pop('lcd_width'),
                 lambda d: d['profiles'][0].update(board='unknown'),
                 lambda d: d['profiles'][1].update(sha256=d['profiles'][0]['sha256'])]
    for mutate in mutations:
        data = copy.deepcopy(family)
        mutate(data)
        path.write_text(json.dumps(data))
        try:
            profiles.load(path)
        except ValueError:
            pass
        else:
            raise AssertionError(data)
    for field, value in [('version', True), ('display', dict(zip(profiles.DISPLAY_KEYS, [720] * 6)))]:
        data = copy.deepcopy(legacy)
        if field == 'version':
            data[field] = value
        else:
            data['profiles'][0][field] = value
        path.write_text(json.dumps(data))
        try:
            profiles.load(path)
        except ValueError:
            pass
        else:
            raise AssertionError('legacy policy widened')
print('PASS generated family policy: 12 synthetic identities, memory/panel/display dispatch, refusal matrix')
