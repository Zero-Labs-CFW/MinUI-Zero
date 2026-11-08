#ifndef ZERO_BOOT_HEALTH_H
#define ZERO_BOOT_HEALTH_H

#include <stddef.h>
#include <stdint.h>

#define ZERO_LOADER_RECORD_SIZE 64u
#define ZERO_HEALTH_TEXT_MAX 65536u
#define ZERO_HEALTH_MENU_MAX 4096u

struct zero_boot_record {
    uint32_t profile, panel, width, height;
    unsigned char build_id[32];
};

/* Pure validators: NULL means accepted, otherwise a static rejection reason. */
const char *zero_boot_record(const unsigned char *data, size_t size,
                            struct zero_boot_record *record);
const char *zero_boot_expected(const unsigned char *data, size_t size,
                              const struct zero_boot_record *record);
const char *zero_boot_cmdline(const unsigned char *data, size_t size,
                             const struct zero_boot_record *record);
const char *zero_boot_display(const unsigned char *data, size_t size,
                             const struct zero_boot_record *record);

#endif
