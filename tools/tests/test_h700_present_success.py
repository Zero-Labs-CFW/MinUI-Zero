#!/usr/bin/env python3
"""Run actual presentation/commit bodies with ioctl failures and no hardware."""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest


class PresentTests(unittest.TestCase):
    def test_only_success_emits_receipt(self):
        source = (Path(__file__).resolve().parents[2] / 'workspace/h700/platform/platform.c').read_text()

        def function(signature):
            start = source.index(signature)
            return source[start:source.index('\n}\n', start) + 3]

        stub = r'''
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define DISP_SHADOW_PROTECT 1
#define DISP_LAYER_SET_CONFIG2 2
#define DISP_HWC_COMMIT 3
#define FBIOPAN_DISPLAY 4
#define FB_ACTIVATE_VBL 1
#define FIXED_BPP 2
#define DISP_PAGES 2
#define LOG_info(...) printf(__VA_ARGS__)
typedef struct { void *pixels; int pitch, h; } SDL_Surface;
static unsigned char pixels[8], ion[2][8], fb[16];
static SDL_Surface screen = {pixels, 2, 1};
static struct {
    struct { uint32_t dwords[16]; } lraw;
    struct { int yoffset, yres, activate; } vinfo;
    int ion_fds[2], dispfd, fdfb, use_disp, page, width, height;
    int game_x, game_y, game_w, game_h, last_present_ui, scrub_pages, pages;
    size_t page_bytes; void *ionmmap[2]; unsigned char *fbmmap;
    SDL_Surface *screen; void *blit;
} vid;
static int disp_shown = -1, disp_backdrop_on, disp_warm = 1, h700_rotate;
static unsigned disp_commit_irq, calls, fail_call, receipts;
static int ioctl(int fd, unsigned cmd, void *arg) {
    (void)fd; (void)cmd; (void)arg; return ++calls == fail_call ? -1 : 0;
}
static int GetNightAlpha(void) { return 255; }
static void disp_backdrop(int on) { (void)on; }
static unsigned disp_irq_now(void) { return 0; }
static void disp_wait_latch(void) {}
static uint32_t SDL_GetTicks(void) { return 1; }
static void dbg_compose(void) {}
static void h700_rot_copy(uint16_t *a, int b, int c, int d, int e, int f, int g, int h,
                          void *i, int j, int k) { (void)a;(void)b;(void)c;(void)d;(void)e;
    (void)f;(void)g;(void)h;(void)i;(void)j;(void)k; }
static void fb_blit565(int page) { (void)page; }
static int usleep(unsigned value) { (void)value; return 0; }
static void first_frame_mark(void) { ++receipts; }
'''
        main = r'''
int main(int argc, char **argv) {
    assert(argc == 4);
    vid.use_disp = atoi(argv[1]); fail_call = atoi(argv[2]);
    vid.blit = atoi(argv[3]) ? &vid : NULL;
    vid.width = vid.height = vid.game_w = vid.game_h = 1;
    vid.screen = &screen; vid.vinfo.yres = 1;
    vid.ionmmap[0] = ion[0]; vid.ionmmap[1] = ion[1]; vid.fbmmap = fb;
    PLAT_flip(NULL,0);
    assert(receipts == (fail_call == 0));
    if (vid.use_disp) assert(disp_shown == (fail_call ? -1 : 0));
    return 0;
}
'''
        body = stub + function('static int disp_commit(int page) {') + '\n' + \
            function('static int fb_pan(int page) {') + '\n' + \
            function('void PLAT_flip(SDL_Surface* IGNORED, int ignored) {') + main
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'test.c').write_text(body)
            subprocess.run(shlex.split(os.environ.get('CC', 'cc')) +
                           ['-std=c11', '-O1', '-g', '-Wall', '-Wextra', '-Werror',
                            '-Wno-unused-parameter', '-fsanitize=address,undefined',
                            str(root / 'test.c'), '-o', str(root / 'test')], check=True)
            for disp in (0, 1):
                for fail in range(5 if disp else 2):
                    for game in (0, 1):
                        subprocess.run([str(root / 'test'), str(disp), str(fail), str(game)], check=True)


if __name__ == '__main__':
    unittest.main()
