#!/usr/bin/env python3
"""Run the actual first-frame marker function with file syscalls redirected to stubs."""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest


class FrameReceiptTests(unittest.TestCase):
    def test_quiet_marker_is_not_a_frame(self):
        source = (Path(__file__).resolve().parents[2] / 'workspace/h700/platform/platform.c').read_text()
        start = source.index('static void first_frame_mark(void) {')
        end = source.index('\n}\n', start) + 3
        function = source[start:end]
        stub = r'''
#include <assert.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/types.h>
static int quiet, frames, logs, quiet_writes;
static int fake_open(const char *p, int flags, ...) {
    (void)flags;
    if (!strcmp(p, "/run/zero-display-frame")) { ++frames; return 10; }
    if (!strcmp(p, "/run/zero-menu-frame")) { ++quiet_writes; return 11; }
    if (!strcmp(p, "/dev/shm/zero-boot")) { ++logs; return 12; }
    assert(!strcmp(p, "/proc/uptime")); return 13;
}
static int fake_close(int fd) { (void)fd; return 0; }
static int fake_access(const char *p, int mode) { (void)mode; assert(!strcmp(p,"/run/zero-menu-frame")); return quiet ? 0 : -1; }
static ssize_t fake_read(int fd, void *p, size_t n) { (void)fd; assert(n >= 10); memcpy(p,"1.00 2.00\n",10); return 10; }
static ssize_t fake_write(int fd, const void *p, size_t n) { (void)fd; (void)p; return n; }
#define F_OK 0
#define open fake_open
#define close fake_close
#define access fake_access
#define read fake_read
#define write fake_write
'''
        main = r'''
int main(int argc, char **argv) {
    (void)argv; quiet = argc > 1;
    first_frame_mark(); first_frame_mark();
    assert(frames == 1);
    assert(logs == !quiet && quiet_writes == !quiet);
    return 0;
}
'''
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'test.c').write_text(stub + function + main)
            subprocess.run(shlex.split(os.environ.get('CC', 'cc')) +
                           ['-std=c11', '-Wall', '-Wextra', '-Werror', str(root / 'test.c'),
                            '-o', str(root / 'test')], check=True)
            subprocess.run([str(root / 'test')], check=True)
            subprocess.run([str(root / 'test'), 'quiet-already-released'], check=True)


if __name__ == '__main__':
    unittest.main()
