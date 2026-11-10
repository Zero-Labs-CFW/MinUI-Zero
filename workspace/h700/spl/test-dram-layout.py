#!/usr/bin/env python3
"""Test the patched production DRAM bound and caller without touching hardware.

Pass a clean upstream U-Boot checkout; a temporary copy receives zero-spl.patch.
The caller is compiled verbatim with mocked training/MMIO, not reimplemented.
"""
import argparse
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('upstream', type=Path)
args = parser.parse_args()
commit = subprocess.check_output(['git', '-C', args.upstream, 'rev-parse', 'HEAD'], text=True).strip()
if commit != '5508406582f6f7120dce0c4b3059819a41788db2':
    parser.error('expected pinned U-Boot v2026.10')
if subprocess.check_output(['git', '-C', args.upstream, 'status', '--porcelain'], text=True):
    parser.error('upstream checkout must be clean')

with tempfile.TemporaryDirectory(prefix='zero-dram-test-') as directory:
    root = Path(directory)
    source = Path('arch/arm/mach-sunxi/dram_sun50i_h616.c')
    target = root / source
    target.parent.mkdir(parents=True)
    target.write_bytes(subprocess.check_output(['git', '-C', args.upstream, 'show', f'HEAD:{source}']))
    subprocess.run(['git', 'apply', '--unsafe-paths', '--include=' + str(source),
                    '--include=arch/arm/mach-sunxi/zero_dram_layout.h',
                    str(HERE / 'zero-spl.patch')], cwd=root, check=True)
    text = target.read_text()
    caller = text[text.index('unsigned long sunxi_dram_init(void)'):]
    if not caller.rstrip().endswith('};'):
        raise AssertionError('inspect changed upstream function boundary')
    harness = r'''
#include <assert.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include "zero_dram_layout.h"
struct dram_config { unsigned int cols, rows, ranks, bus_full_width; };
static struct { unsigned int tpr11, tpr12; } para = {1, 1};
static struct dram_config detected;
static unsigned long probed_size;
static int init_ok, inits, probes, priorities, mmio;
static unsigned char prcm_stub[16];
#define SUNXI_PRCM_BASE prcm_stub
#define CCU_PRCM_RES_CAL_CTRL 0
#define CCU_PRCM_OHMS240 4
#define BIT(n) (1U << (n))
#define setbits_le32(p, v) ((void)(p), (void)(v), ++mmio)
#define clrbits_le32(p, v) ((void)(p), (void)(v), ++mmio)
#define mctl_auto_detect_rank_width(p, c) ((void)(p), *(c) = detected)
#define mctl_auto_detect_dram_size(p, c) ((void)(p), (void)(c))
#define mctl_core_init(p, c) ((void)(p), (void)(c), ++inits, init_ok)
#define mctl_calc_size(c) ((void)(c), ++probes, probed_size)
#define mctl_set_master_priority() (++priorities)
'''
    harness += caller + r'''
static void reset(void) {
    inits = probes = priorities = mmio = 0;
    init_ok = 1; probed_size = 0x40000000UL;
    detected = (struct dram_config){10, 15, 1, 1};
    para.tpr11 = para.tpr12 = 1;
}
int main(void) {
    unsigned long checks = 0;
    for (unsigned int c = 0; c < 256; ++c)
    for (unsigned int r = 0; r < 256; ++r)
    for (unsigned int n = 0; n < 4; ++n)
    for (unsigned int w = 0; w < 3; ++w) {
        unsigned long long expected = 0;
        if (c >= 8 && c <= 11 && r >= 13 && r <= 17 &&
            (n == 1 || n == 2) && w <= 1) {
            expected = (1ULL << (c + r + 3)) * (w ? 4 : 2) * n;
            if (expected > 0x80000000ULL) expected = 0;
        }
        assert(zero_dram_layout_size(c, r, n, w) == expected);
        reset(); detected = (struct dram_config){c, r, n, w};
        assert(sunxi_dram_init() == (expected ? probed_size : 0));
        assert(inits == !!expected && probes == !!expected && priorities == !!expected);
        ++checks;
    }
    assert(!zero_dram_layout_size(UINT_MAX, 15, 1, 1));
    assert(!zero_dram_layout_size(10, UINT_MAX, 1, 1));
    assert(!zero_dram_layout_size(10, 15, UINT_MAX, 1));
    assert(!zero_dram_layout_size(10, 15, 1, UINT_MAX));
    assert(zero_dram_layout_size(10, 15, 1, 1) == 0x40000000ULL);
    assert(zero_dram_layout_size(10, 16, 1, 1) == 0x80000000ULL);
    reset(); init_ok = 0;
    assert(!sunxi_dram_init() && inits == 1 && !probes && !priorities);
    reset(); probed_size = 0;
    assert(!sunxi_dram_init() && inits == 1 && probes == 1 && !priorities);
    reset(); detected.rows = 16; probed_size = 0x80000000UL;
    assert(sunxi_dram_init() == 0x80000000UL && priorities == 1);
#ifdef CONFIG_SUNXI_DRAM_H616_LPDDR3
    reset(); para.tpr11 = 0;
    assert(!sunxi_dram_init() && !mmio && !inits && !probes);
    reset(); para.tpr12 = 0;
    assert(!sunxi_dram_init() && !mmio && !inits && !probes);
#endif
    printf("PASS %lu layout/caller combinations + failure ordering\n", checks);
}
'''
    test = root / 'test.c'
    test.write_text(harness)
    cc = shlex.split(os.environ.get('CC', 'cc'))
    env = dict(os.environ, ASAN_OPTIONS='detect_leaks=' + ('0' if sys.platform == 'darwin' else '1') + ':halt_on_error=1',
               UBSAN_OPTIONS='halt_on_error=1')
    for lp3 in (False, True):
        binary = root / ('lp3' if lp3 else 'lp4')
        subprocess.run([*cc, '-std=gnu11', '-O1', '-g', '-Wall', '-Wextra', '-Werror',
                        '-fsanitize=address,undefined', '-fno-omit-frame-pointer',
                        *(['-DCONFIG_SUNXI_DRAM_H616_LPDDR3'] if lp3 else []),
                        '-I', target.parent, test, '-o', binary], check=True)
        subprocess.run([binary], env=env, check=True)
print('PASS patched production code; MMIO/training mocked, no hardware qualification')
