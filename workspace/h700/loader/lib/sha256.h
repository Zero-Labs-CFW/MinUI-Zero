/* SPDX-License-Identifier: GPL-2.0+ */
/* U-Boot v2026.10 standalone subset of include/u-boot/sha256.h. */
#ifndef ZL_SHA256_H
#define ZL_SHA256_H
#include <stdint.h>
#define SHA256_DER_LEN 19
typedef struct {
    uint32_t total[2];
    uint32_t state[8];
    uint8_t buffer[64];
} sha256_context;
void sha256_starts(sha256_context *ctx);
void sha256_update(sha256_context *ctx, const uint8_t *input, uint32_t length);
void sha256_finish(sha256_context *ctx, uint8_t digest[32]);
#endif
