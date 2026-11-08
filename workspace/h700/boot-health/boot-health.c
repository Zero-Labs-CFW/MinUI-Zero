#define _POSIX_C_SOURCE 200809L
#define _DARWIN_C_SOURCE
#include "boot_health.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

/* O_NOFOLLOW protects the leaf; sysfs has legitimate symlink ancestors. */
static const char *read_file(const char *path, unsigned char *data, size_t cap,
                             size_t *size) {
    struct stat st;
    size_t used = 0;
    int fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    const char *error = NULL;
    if (fd < 0) return "open failed";
    if (fstat(fd, &st) < 0) error = "fstat failed";
    else if (!S_ISREG(st.st_mode)) error = "not a regular/sysfs file";
    while (!error) {
        unsigned char extra;
        ssize_t n = read(fd, used < cap ? data + used : &extra,
                         used < cap ? cap - used : 1);
        if (n < 0) {
            if (errno == EINTR) continue;
            error = "read failed";
        } else if (!n) break;
        else if (used == cap) error = "file too large";
        else used += (size_t)n;
    }
    if (close(fd) < 0 && !error) error = "close failed";
    *size = used;
    return error;
}

static void usage(const char *name) {
    fprintf(stderr, "usage: %s [--record PATH] [--expected PATH] [--cmdline PATH] "
                    "[--display PATH] [--menu PATH]\n", name);
}

int main(int argc, char **argv) {
    const char *names[] = {"--record", "--expected", "--cmdline", "--display", "--menu"};
    const char *paths[] = {
        "/sys/firmware/devicetree/base/chosen/zero,loader",
        "/opt/minui-zero/loader/build-id", "/proc/cmdline",
        "/sys/class/disp/disp/attr/sys", "/run/zero-display-frame"
    };
    const size_t caps[] = {64, 65, ZERO_HEALTH_TEXT_MAX, ZERO_HEALTH_TEXT_MAX, ZERO_HEALTH_MENU_MAX};
    unsigned seen = 0;
    unsigned char data[ZERO_HEALTH_TEXT_MAX];
    struct zero_boot_record record;
    int i;
    for (i = 1; i < argc; i += 2) {
        size_t k;
        if (i + 1 == argc || !argv[i + 1][0]) { usage(argv[0]); return 2; }
        for (k = 0; k < 5 && strcmp(argv[i], names[k]); ++k) {}
        if (k == 5 || (seen & (1u << k))) { usage(argv[0]); return 2; }
        seen |= 1u << k;
        paths[k] = argv[i + 1];
    }
    for (i = 0; i < 5; ++i) {
        size_t size = 0;
        const char *error = read_file(paths[i], data, caps[i], &size);
        if (!error) {
            switch (i) {
            case 0: error = zero_boot_record(data, size, &record); break;
            case 1: error = zero_boot_expected(data, size, &record); break;
            case 2: error = zero_boot_cmdline(data, size, &record); break;
            case 3: error = zero_boot_display(data, size, &record); break;
            default: break; /* Current-boot PLAT_flip marker, not quiet-window release. */
            }
        }
        if (error) {
            fprintf(stderr, "boot-health: reject %s (%s): %s\n", names[i] + 2, paths[i], error);
            return 1;
        }
    }
    puts("boot-health: accepted");
    return 0;
}
