#define _POSIX_C_SOURCE 200809L
#define _DARWIN_C_SOURCE
#include "boot_health.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

static size_t read_chunk;
static int interrupt_read, fail_read, fail_close;
static ssize_t test_read(int fd, void *buf, size_t size) {
    if (interrupt_read) { interrupt_read = 0; errno = EINTR; return -1; }
    if (fail_read) { errno = EIO; return -1; }
    if (read_chunk && size > read_chunk) size = read_chunk;
    return read(fd, buf, size);
}
static int test_close(int fd) {
    int rc = close(fd);
    if (fail_close) { errno = EIO; return -1; }
    return rc;
}

/* Compile the production CLI unchanged except for deterministic I/O faults. */
#define read test_read
#define close test_close
#define main boot_health_cli_main
#include "boot-health.c"
#undef main
#undef close
#undef read

static unsigned checks;
#define CHECK(expr) do { ++checks; if (!(expr)) { \
    fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #expr); exit(1); \
} } while (0)

/* Saved normal-loader-1-peripherals/display.txt, including the real BUF layout. */
static const char display[] =
    "screen 0:\n"
    "de_rate 696000000 hz, ref_fps:60\n"
    "mgr0: 640x480 fmt[rgb] cs[0x204] range[full] eotf[0x4] bits[8bits] err[0] force_sync[0] unblank direct_show[false] iommu[0]\n"
    "dmabuf: cache[4] cache max[4] umap skip[0] umap skip max[0]\n"
    "\tlcd output\tbacklight( 88)\tfps:22.5\t 640x 480\n"
    "\terr:0\tskip:0\tirq:9722\tvsync:0\tvsync_skip:0\t\n"
    "   BUF    enable ch[1] lyr[0] z[20] prem[N] a[globl 255] fmt[ 10] fb[ 640, 480;   0,   0;   0,   0] crop[   0,   0, 640, 480] frame[   0,   0, 640, 480] addr[ff000000,ff04b000,ff096000] flags[0x       0] trd[0,0]\n"
    "depth[ 0] transf[0]\n";

static unsigned char raw[65], expected[66];
static struct zero_boot_record record;

static void put32(unsigned char *p, uint32_t n) {
    p[0] = (unsigned char)(n >> 24); p[1] = (unsigned char)(n >> 16);
    p[2] = (unsigned char)(n >> 8); p[3] = (unsigned char)n;
}

static void baseline(unsigned profile, unsigned panel) {
    size_t i;
    static const char hex[] = "0123456789abcdef";
    memset(raw, 0, sizeof(raw));
    memcpy(raw, "ZHL1", 4);
    put32(raw + 4, 1); put32(raw + 8, 64); put32(raw + 12, profile);
    put32(raw + 16, panel); put32(raw + 20, 640); put32(raw + 24, 480);
    for (i = 0; i < 32; ++i) {
        raw[i + 32] = (unsigned char)i;
        expected[i * 2] = (unsigned char)hex[i >> 4];
        expected[i * 2 + 1] = (unsigned char)hex[i & 15];
    }
    expected[64] = '\n'; expected[65] = '\0';
    CHECK(zero_boot_record(raw, 64, &record) == NULL);
}

static void display_change(const char *from, const char *to) {
    char buf[4096];
    const char *p = strstr(display, from);
    size_t prefix;
    CHECK(p != NULL);
    prefix = (size_t)(p - display);
    CHECK(prefix + strlen(to) + strlen(p + strlen(from)) < sizeof(buf));
    memcpy(buf, display, prefix);
    strcpy(buf + prefix, to);
    strcat(buf, p + strlen(from));
    CHECK(zero_boot_display((const unsigned char *)buf, strlen(buf), &record) != NULL);
}

static void pure_tests(void) {
    size_t i;
    const size_t fields[] = {4, 8, 12, 16, 20, 24, 28};
    const uint32_t bad[] = {2, 63, 3, 2, 0, 0, 1};
    const char *bad_cmd[] = {
        "", "quiet", "lcd_type", "lcd_type=", "lcd_type=OLD", "lcd_type=other",
        "lcd_type=boe", "lcd_type=oldx", "lcd_type=old lcd_type=old",
        "lcd_type=old lcd_type=boe", "lcd_type=old lcd_type", "xlcd_type=old"
    };
    unsigned profile, panel;
    for (profile = 1; profile <= 2; ++profile) {
        for (panel = 0; panel <= 1; ++panel) {
            const char *cmd = panel ? "quiet lcd_type=boe\n" : "quiet lcd_type=old\n";
            baseline(profile, panel);
            CHECK(zero_boot_expected(expected, 64, &record) == NULL);
            CHECK(zero_boot_expected(expected, 65, &record) == NULL);
            CHECK(zero_boot_cmdline((const unsigned char *)cmd, strlen(cmd), &record) == NULL);
            CHECK(zero_boot_display((const unsigned char *)display, strlen(display), &record) == NULL);
        }
    }
    baseline(1, 0);
    for (i = 0; i < 64; ++i) CHECK(zero_boot_record(raw, i, &record) != NULL);
    CHECK(zero_boot_record(raw, 65, &record) != NULL);
    for (i = 0; i < 4; ++i) {
        raw[i] ^= 1; CHECK(zero_boot_record(raw, 64, &record) != NULL); raw[i] ^= 1;
    }
    for (i = 0; i < sizeof(fields) / sizeof(fields[0]); ++i) {
        baseline(1, 0); put32(raw + fields[i], bad[i]);
        CHECK(zero_boot_record(raw, 64, &record) != NULL);
    }
    baseline(1, 0); put32(raw + 12, 0);
    CHECK(zero_boot_record(raw, 64, &record) != NULL);
    baseline(1, 0);
    for (i = 0; i < 32; ++i) {
        raw[32 + i] ^= 1;
        CHECK(zero_boot_record(raw, 64, &record) == NULL);
        CHECK(zero_boot_expected(expected, 64, &record) != NULL);
        raw[32 + i] ^= 1;
    }
    baseline(1, 0);
    for (i = 0; i < 64; ++i) CHECK(zero_boot_expected(expected, i, &record) != NULL);
    CHECK(zero_boot_expected(expected, 66, &record) != NULL);
    expected[64] = '\r'; CHECK(zero_boot_expected(expected, 65, &record) != NULL);
    expected[64] = '\n'; expected[3] = 'g';
    CHECK(zero_boot_expected(expected, 64, &record) != NULL);
    baseline(1, 0); expected[63] = 'F';
    CHECK(zero_boot_expected(expected, 64, &record) == NULL);
    for (i = 0; i < sizeof(bad_cmd) / sizeof(bad_cmd[0]); ++i)
        CHECK(zero_boot_cmdline((const unsigned char *)bad_cmd[i], strlen(bad_cmd[i]), &record) != NULL);
    CHECK(zero_boot_cmdline((const unsigned char *)"lcd_type=old\0lcd_type=boe", 25, &record) != NULL);
    display_change("mgr0: 640x480", "mgr0: 320x240");
    display_change("mgr0: 640x480", "mgr0: 640x480junk");
    display_change("mgr0:", "mgr1:");
    display_change("640x 480", "640x 481");
    display_change("lcd output", "hdmi output");
    display_change("err[0]", "err[1]");
    display_change("err:0", "err:1");
    display_change("err:0", "err:-1");
    display_change("err:0", "err:4294967296");
    display_change("err:0", "skip:0");
    display_change("unblank", "blank");
    display_change("unblank", "blank unblank");
    display_change("BUF    enable", "BUF    disable");
    display_change("frame[", "frame_missing[");
    display_change("frame[   0,   0, 640, 480]", "frame[   0,   0, 320, 240]");
    display_change("frame[   0,   0, 640, 480]", "frame[   1,   0, 640, 480]");
    display_change("mgr0: 640x480", "mgr0: 4294967296x480");
    display_change("640x 480", "0x 480");
    display_change("depth[ 0]", "err[2]");
    CHECK(zero_boot_display((const unsigned char *)display, 0, &record) != NULL);
    CHECK(zero_boot_display((const unsigned char *)display, 100, &record) != NULL);
    {
        char dup[2048];
        snprintf(dup, sizeof(dup), "%s%s", display, display);
        CHECK(zero_boot_display((const unsigned char *)dup, strlen(dup), &record) != NULL);
    }
}

static void write_file(const char *path, const void *data, size_t size) {
    const unsigned char *p = data;
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    CHECK(fd >= 0);
    while (size) {
        ssize_t n = write(fd, p, size);
        CHECK(n > 0); p += n; size -= (size_t)n;
    }
    CHECK(close(fd) == 0);
}

static void cli_check(char **args, int expected_status) {
    int status;
    pid_t pid = fork();
    CHECK(pid >= 0);
    if (!pid) {
        int nullfd = open("/dev/null", O_WRONLY);
        if (nullfd < 0 || dup2(nullfd, 1) < 0 || dup2(nullfd, 2) < 0) _exit(99);
        close(nullfd);
        _exit(boot_health_cli_main(11, args));
    }
    CHECK(waitpid(pid, &status, 0) == pid);
    CHECK(WIFEXITED(status) && WEXITSTATUS(status) == expected_status);
}

static void io_tests(const char *dir) {
    char paths[5][1024];
    char *args[] = {"boot-health", "--record", paths[0], "--expected", paths[1],
                    "--cmdline", paths[2], "--display", paths[3], "--menu", paths[4], NULL};
    const void *data[] = {raw, expected, "quiet lcd_type=old\n", display, ""};
    size_t sizes[] = {64, 65, 19, sizeof(display) - 1, 0};
    unsigned i, profile, panel;
    unsigned char oversized[ZERO_HEALTH_TEXT_MAX + 1];
    baseline(1, 0);
    sizes[2] = strlen(data[2]);
    memset(oversized, 'x', sizeof(oversized));
    for (i = 0; i < 5; ++i) {
        CHECK(snprintf(paths[i], sizeof(paths[i]), "%s/input%u", dir, i) < (int)sizeof(paths[i]));
        write_file(paths[i], data[i], sizes[i]);
    }
    cli_check(args, 0);
    for (profile = 1; profile <= 2; ++profile) {
        for (panel = 0; panel <= 1; ++panel) {
            const char *cmd = panel ? "lcd_type=boe" : "lcd_type=old";
            baseline(profile, panel);
            write_file(paths[0], raw, 64);
            write_file(paths[2], cmd, strlen(cmd));
            cli_check(args, 0);
        }
    }
    baseline(1, 0);
    for (i = 0; i < 5; ++i) write_file(paths[i], data[i], sizes[i]);
    read_chunk = 1; interrupt_read = 1; cli_check(args, 0);
    read_chunk = 7; cli_check(args, 0); read_chunk = 0;
    fail_read = 1; cli_check(args, 1); fail_read = 0;
    fail_close = 1; cli_check(args, 1); fail_close = 0;
    for (i = 0; i < 5; ++i) {
        size_t too_large[] = {65, 66, ZERO_HEALTH_TEXT_MAX + 1, ZERO_HEALTH_TEXT_MAX + 1, ZERO_HEALTH_MENU_MAX + 1};
        CHECK(unlink(paths[i]) == 0); cli_check(args, 1);
        CHECK(symlink(paths[(i + 1) % 5], paths[i]) == 0); cli_check(args, 1);
        CHECK(unlink(paths[i]) == 0);
        CHECK(mkdir(paths[i], 0700) == 0); cli_check(args, 1);
        CHECK(rmdir(paths[i]) == 0);
        CHECK(mkfifo(paths[i], 0600) == 0); cli_check(args, 1);
        CHECK(unlink(paths[i]) == 0);
        write_file(paths[i], oversized, too_large[i]); cli_check(args, 1);
        if (i != 4) { write_file(paths[i], data[i], 0); cli_check(args, 1); }
        write_file(paths[i], data[i], sizes[i]);
        cli_check(args, 0);
    }
    write_file(paths[0], raw, 63); cli_check(args, 1);
    write_file(paths[0], raw, 64);
    expected[0] = 'f'; write_file(paths[1], expected, 64); cli_check(args, 1);
    baseline(1, 0); write_file(paths[1], expected, 64);
    write_file(paths[2], "lcd_type=old lcd_type=old", 25); cli_check(args, 1);
    write_file(paths[2], data[2], sizes[2]);
    write_file(paths[3], "mgr0: 640x480 err[0] unblank\n",
               sizeof("mgr0: 640x480 err[0] unblank\n") - 1); cli_check(args, 1);
    write_file(paths[3], display, sizeof(display) - 1);
    args[1] = "--bypass"; cli_check(args, 2); args[1] = "--record";
    args[9] = "--record"; cli_check(args, 2); args[9] = "--menu";
    for (i = 0; i < 5; ++i) CHECK(unlink(paths[i]) == 0);
}

int main(int argc, char **argv) {
    CHECK(argc == 2);
    pure_tests();
    io_tests(argv[1]);
    printf("boot-health: %u checks passed\n", checks);
    return 0;
}
