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
#include <stdint.h>
#include <time.h>
#include <unistd.h>
static int quiet, frames, logs, quiet_writes, fail_clock, fail_id, metadata;
static int fake_open(const char *p, int flags, ...) {
    (void)flags;
    if (!strcmp(p, "/run/zero-display-frame")) { ++frames; return 10; }
    if (!strcmp(p, "/run/zero-menu-frame")) { ++quiet_writes; return 11; }
    if (!strcmp(p, "/dev/shm/zero-boot")) { ++logs; return 12; }
    if (!strcmp(p, "/proc/sys/kernel/random/boot_id")) return fail_id ? -1 : 14;
    assert(!strcmp(p, "/proc/uptime")); return 13;
}
static int fake_close(int fd) { (void)fd; return 0; }
static int fake_access(const char *p, int mode) { (void)mode; assert(!strcmp(p,"/run/zero-menu-frame")); return quiet ? 0 : -1; }
static ssize_t fake_read(int fd, void *p, size_t n) {
    if (fd == 14) {
        assert(n >= 37); memcpy(p,"42248cd7-52eb-4dd9-88cc-a261d8037b59\n",37); return 37;
    }
    assert(n >= 10); memcpy(p,"1.00 2.00\n",10); return 10;
}
static ssize_t fake_write(int fd, const void *p, size_t n) {
    if (fd == 10) {
        const char *expected = "v1 boot=42248cd7-52eb-4dd9-88cc-a261d8037b59 raw_ns=1000000000\n";
        assert(n == strlen(expected) && !memcmp(p, expected, n)); ++metadata;
    }
    return n;
}
static int fake_clock_gettime(clockid_t id, struct timespec *ts) {
    assert(id == CLOCK_MONOTONIC_RAW);
    ts->tv_sec = 1; ts->tv_nsec = 0; return fail_clock ? -1 : 0;
}
#define F_OK 0
#define open fake_open
#define close fake_close
#define access fake_access
#define read fake_read
#define write fake_write
#define clock_gettime fake_clock_gettime
#include "display_receipt.h"
'''
        main = r'''
int main(int argc, char **argv) {
    quiet = argc > 1 && !strcmp(argv[1], "quiet");
    fail_clock = argc > 2 && !strcmp(argv[2], "clock-fail");
    fail_id = argc > 2 && !strcmp(argv[2], "id-fail");
    first_frame_mark(); first_frame_mark();
    assert(frames == 1);
    assert(metadata == (!fail_clock && !fail_id));
    assert(logs == !quiet && quiet_writes == !quiet);
    return 0;
}
'''
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'test.c').write_text(stub + function + main)
            subprocess.run(shlex.split(os.environ.get('CC', 'cc')) +
                           ['-std=gnu11', '-Wall', '-Wextra', '-Werror',
                            '-I', str(Path(__file__).resolve().parents[2] / 'workspace/h700/platform'), str(root / 'test.c'),
                            '-o', str(root / 'test')], check=True)
            for quiet in ('normal', 'quiet'):
                for failure in ('none', 'clock-fail', 'id-fail'):
                    subprocess.run([str(root / 'test'), quiet, failure], check=True)


if __name__ == '__main__':
    unittest.main()
