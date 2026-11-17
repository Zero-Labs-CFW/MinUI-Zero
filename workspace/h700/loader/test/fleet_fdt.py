#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0+
"""Actual fleet tuples -> production fixup/libfdt -> real boot-health CLI.

python3 -B test/fleet_fdt.py --packaged /path/to/boards-stage --output /path/to/notes/fleetfdt
All RAM values are input requirements, never measurements. Valid staged boot0
words are metadata fixtures, not training results for a new physical unit.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import struct
import subprocess
import sys
import tempfile

LOADER = Path(__file__).resolve().parents[1]
HEALTH = LOADER.parent / 'boot-health'
DRAM_NAMES = ('dram_clk', 'dram_type', 'dram_zq', 'dram_odt_en', 'dram_para1', 'dram_para2',
              'dram_mr0', 'dram_mr1', 'dram_mr2', 'dram_mr3', 'dram_tpr0', 'dram_tpr1',
              'dram_tpr2', 'dram_tpr3', 'dram_tpr4', 'dram_tpr5', 'dram_tpr6', 'dram_tpr7',
              'dram_tpr8', 'dram_tpr9', 'dram_tpr10', 'dram_tpr11', 'dram_tpr12', 'dram_tpr13')


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    sys.modules[name] = result
    spec.loader.exec_module(result)
    return result


def sha(data):
    return hashlib.sha256(data).hexdigest()


def run(command, **kwargs):
    subprocess.run([str(p) for p in command], check=True, **kwargs)


def boot0_metadata(path, row):
    data = path.read_bytes()
    if len(data) != 65536 or data[4:12] != b'eGON.BT0' or struct.unpack_from('<I', data, 16)[0] != len(data):
        raise ValueError(f'{path}: invalid boot0 magic/length; no synthetic fallback')
    words = struct.unpack('<16384I', data)
    expected = (sum(words) - words[3] + 0x5f0a6c39) & 0xffffffff
    if words[3] != expected:
        raise ValueError(f'{path}: invalid boot0 checksum; no synthetic fallback')
    dram = struct.unpack_from('<32I', data, 0x38)
    if dram[1] not in row['dram_types'] or dram[7] >> 16 != row['ram_mib']:
        raise ValueError(f'{path}: boot0 type/size differs from profile requirement; explicit fixture needed')
    return data[0x38:0xb8], {'path': str(path), 'sha256': sha(data), 'checksum_valid': True,
                              'type_code': dram[1], 'pin_ram_mib': dram[7] >> 16,
                              'ram_mib_requirement': row['ram_mib'], 'is_measured': False,
                              'synthetic_dram_words': False}


def verify_tree(parse, before_path, output, row, strap, dram, build_id, ramdisk_len):
    before, reserved = parse(before_path)
    after, actual_reserved = parse(output)
    assert before.keys() == after.keys(), 'unexpected node addition/removal'
    allowed = {'/chosen': {'bootargs', 'zero,loader', 'linux,initrd-start', 'linux,initrd-end'},
               '/dram': set(DRAM_NAMES), '/memory@40000000': {'reg'}}
    properties = 0
    for path in before:
        for name in before[path].keys() | after[path].keys():
            if name not in allowed.get(path, set()):
                assert before[path].get(name) == after[path].get(name), (path, name)
                properties += 1
    words = struct.unpack('<32I', dram)
    for i, name in enumerate(DRAM_NAMES):
        assert after['/dram'][name] == struct.pack('>I', words[i] | (0x80000000 if i == 23 else 0))
    assert after['/memory@40000000']['reg'] == struct.pack('>QQ', 0x40000000, row['ram_mib'] << 20)
    assert after['/chosen']['linux,initrd-start'] == struct.pack('>Q', 0x42000000)
    assert after['/chosen']['linux,initrd-end'] == struct.pack('>Q', 0x42000000 + ramdisk_len)
    assert actual_reserved == reserved + [(0x42000000, ramdisk_len)]
    rule = row['panel_rule']
    token = rule if rule in ('old', 'boe') else ('old' if strap else 'boe')
    record = after['/chosen']['zero,loader']
    dims = row['display']
    width, height = dims['lcd_width'], dims['lcd_height']
    assert record == b'ZHL1' + struct.pack('>7I', 1, 64, row['id'], token == 'boe', width, height, 0) + build_id
    assert (width, height) == (dims['manager_width'], dims['manager_height']) == (dims['frame_width'], dims['frame_height'])
    lcd = after['/soc@03000000/lcd0@01c0c000']
    assert lcd['lcd_x'] == struct.pack('>I', width) and lcd['lcd_y'] == struct.pack('>I', height)
    args = after['/chosen']['bootargs'].rstrip(b'\0')
    assert [v for v in args.split() if v.startswith(b'lcd_type=')] == [('lcd_type=' + token).encode()]
    assert b'bootreason=button' in args.split() and b'androidboot.mode=normal' in args.split()
    assert not any(v.startswith(b'disp_reserve=') for v in args.split())
    return record, args + b'\n', properties


def health_cases(helper, directory, record, cmdline, display, build_id, env):
    data = {'record': record, 'expected': build_id.hex().encode() + b'\n',
            'cmdline': cmdline, 'display': display, 'menu': b'1\n'}
    command = [str(helper)]
    for name in data:
        command += ['--' + name, str(directory / name)]
    def check(changes, accepted):
        for name, value in (data | changes).items():
            (directory / name).write_bytes(value)
        result = subprocess.run(command, capture_output=True, text=True, env=env)
        assert result.returncode == (0 if accepted else 1), (result.returncode, result.stderr)
    check({}, True)
    changed = bytearray(record)
    changed[12:16] = struct.pack('>I', 255)
    check({'record': changed}, False)
    check({'expected': b'0' * 64 + b'\n'}, False)
    check({'cmdline': cmdline + b' lcd_type=old'}, False)
    check({'display': display.replace(b'err[0]', b'err[1]')}, False)
    return 5


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--packaged', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path, help='notes/results directory; no builds written here')
    args = parser.parse_args()
    gen = module('fleet_genprofiles', LOADER / 'tools/genprofiles.py')
    policy = module('fleet_profiles', LOADER / 'tools/profiles.py')
    offline = module('fleet_offline', LOADER / 'test/offline.py')
    rows = policy.load(LOADER / 'profiles.json')
    assert [r['id'] for r in rows] == list(range(1, 12)), 'requires explicit eleven-profile manifest'
    cohorts = gen.load_packaged(args.packaged, rows)
    gen.validate_public(cohorts)
    source_paths = [LOADER / name for name in ('test/fleet_fdt.c', 'test/fleet_fdt.py', 'test/offline.py',
                    'test/offline_soc.c', 'test/offline_soc.h', 'test/offline_util.h', 'fixup.c', 'rtc.c',
                    'rtc.h', 'zl.h', 'zero_params.h', 'display_contract.h', 'profile_policy.h',
                    'profile_policy.inc', 'profiles.json', 'profiles.inc', 'obj/build_id.h',
                    'tools/genprofiles.py', 'tools/profiles.py')]
    source_paths += sorted((LOADER / 'libfdt').glob('*.[ch]'))
    source_paths += sorted((LOADER / 'include').rglob('*.h'))
    source_paths += [HEALTH / n for n in ('boot-health.c', 'boot_health.c', 'boot_health.h')]
    snapshot = lambda: {str(p): sha(p.read_bytes()) for p in source_paths}
    before = snapshot()
    build_header = (LOADER / 'obj/build_id.h').read_text()
    build_id = bytes(int(v, 16) for v in re.findall(r'0x([0-9a-fA-F]{2})', build_header))
    assert len(build_id) == 32, 'unsupported build-id header'
    env = dict(os.environ, ASAN_OPTIONS='detect_leaks=' + ('0' if sys.platform == 'darwin' else '1') + ':halt_on_error=1',
               UBSAN_OPTIONS='halt_on_error=1:print_stacktrace=1')
    cc = shlex.split(os.environ.get('CC', 'cc'))
    sanitize = ['-fsanitize=address,undefined', '-fno-omit-frame-pointer']
    results = []
    with tempfile.TemporaryDirectory(prefix='zero-fleet-fdt-') as temporary:
        tmp = Path(temporary)
        exe, helper = tmp / 'fleet-fdt', tmp / 'boot-health'
        sources = [LOADER / n for n in ('test/fleet_fdt.c', 'test/offline_soc.c', 'fixup.c', 'rtc.c')]
        sources += sorted((LOADER / 'libfdt').glob('*.c'))
        run(cc + ['-std=gnu11', '-O1', '-g', '-D__UBOOT__', '-DFREESTANDING', '-DZL_HOST_TEST',
                  '-fno-strict-aliasing', '-I' + str(LOADER), '-I' + str(LOADER / 'include'),
                  '-I' + str(LOADER / 'libfdt')] + sanitize + sources + ['-o', exe])
        run(cc + ['-std=c99', '-O1', '-g', '-Wall', '-Wextra', '-Werror', '-pedantic',
                  '-DZERO_HEALTH_BUILD_ID="' + build_id.hex() + '"'] + sanitize +
            [HEALTH / 'boot-health.c', HEALTH / 'boot_health.c', '-o', helper])
        assert subprocess.check_output([helper, '--build-id'], text=True, env=env).strip() == build_id.hex()
        for cohort, row in zip(cohorts, rows):
            dram, provenance = boot0_metadata(gen.packaged_path(args.packaged.resolve(), cohort.folder, 'boot0.img'), row)
            case = tmp / cohort.folder
            case.mkdir()
            for name, data in (('input.dtb', cohort.parts[3]), ('header', cohort.parts[5]),
                               ('overlay', cohort.parts[4]), ('dram', dram)):
                (case / name).write_bytes(data)
            for strap in (0, 1):
                output = case / f'output-{strap}.dtb'
                run([exe, case / 'input.dtb', case / 'header', case / 'overlay', case / 'dram',
                     row['id'], row['ram_mib'], strap, output], env=env)
                record, cmdline, count = verify_tree(offline.parse_fdt, case / 'input.dtb', output,
                                                    row, strap, dram, build_id, len(cohort.parts[7]))
                width, height = row['display']['manager_width'], row['display']['manager_height']
                display = (f'screen 0:\n mgr0: {width}x{height} err[0] unblank\n'
                           f' lcd output backlight(88) fps:60.0 {width}x {height}\n'
                           f' err:0\n BUF enable frame[0,0,{width},{height}]\n').encode()
                health_count = health_cases(helper, case, record, cmdline, display, build_id, env)
                results.append({'id': row['id'], 'board': row['board'], 'strap_fixture': strap,
                                'tuple_sha256': cohort.digest.hex(), 'boot0_metadata': provenance,
                                'output_fdt_sha256': sha(output.read_bytes()),
                                'unchanged_property_checks': count, 'health_cli_checks': health_count})
        assert snapshot() == before, 'sources changed during run; repeat on a stable snapshot'
    args.output.mkdir(parents=True, exist_ok=True)
    result = {'result': 'PASS', 'scope': 'Offline host entry-state fixtures, not measured RAM/DRAM/panel or hardware qualification',
              'sanitizers': ['address', 'undefined'], 'build_id_from_existing_compiled_header': build_id.hex(),
              'source_hashes': before, 'cases': results,
              'gaps': ['No device or SPL/preflight execution; exact artifacts checked before calling FDT builder.',
                       'SID/PMIC/strap/RAM requirement are host fixtures. Valid boot0 words are archived metadata, not per-unit training proof.',
                       'No synthetic DRAM fallback: invalid or requirement-mismatched boot0 aborts explicitly.',
                       'Display/menu text supplied to real CLI is synthetic expected state, not live scanout or menu health.',
                       'Panel behavior is production policy under mocked registers, not source-U-Boot equivalence or physical strap validation.']}
    (args.output / 'results.json').write_text(json.dumps(result, indent=2) + '\n')
    print(f'PASS {len(results)} production FDT cases, {sum(r["health_cli_checks"] for r in results)} real CLI checks; '
          'critical nodes unchanged; ASan/UBSan clean; no measured-unit claims')


if __name__ == '__main__':
    main()
