/* SPDX-License-Identifier: GPL-2.0+ */
/* Called before _start: only const image data, caller stack and immutable inputs.
 * No BSS, heap, MMIO, cache/MMU changes, or writes to any package/boot component. */
#include <stdint.h>
#include <string.h>
#include "profile.h"
#include "lib/sha256.h"
#include "profiles.inc"

static uint32_t le32(const void *p)
{
    const uint8_t *b = p;
    return b[0] | (uint32_t)b[1]<<8 | (uint32_t)b[2]<<16 | (uint32_t)b[3]<<24;
}

static void hash_word(sha256_context *ctx, uint32_t v)
{
    uint8_t b[4] = {v, v>>8, v>>16, v>>24};
    sha256_update(ctx, b, sizeof(b));
}

unsigned int zl_profile_match(const void *const parts[ZL_PROFILE_PARTS],
                             const uint32_t lengths[ZL_PROFILE_PARTS], uint32_t ram_mib)
{
    sha256_context ctx;
    uint8_t hash[32];
    unsigned int i, row;
    int candidate = 0;

    /* Reject unknown lengths before hashing, bounding time and all memory reads. */
    for (row = 0; row < sizeof(profiles)/sizeof(profiles[0]); row++) {
        if (profiles[row].ram_mib == ram_mib &&
            !memcmp(profiles[row].lengths, lengths, sizeof(profiles[row].lengths)))
            candidate = 1;
    }
    if (!candidate)
        return 0;
    sha256_starts(&ctx);
    hash_word(&ctx, ram_mib);
    for (i = 0; i < ZL_PROFILE_PARTS; i++) {
        if (lengths[i] && !parts[i])
            return 0;
        hash_word(&ctx, lengths[i]);
        if (lengths[i])
            sha256_update(&ctx, parts[i], lengths[i]);
    }
    sha256_finish(&ctx, hash);
    for (row = 0; row < sizeof(profiles)/sizeof(profiles[0]); row++) {
        if (profiles[row].ram_mib == ram_mib &&
            !memcmp(profiles[row].lengths, lengths, sizeof(profiles[row].lengths)) &&
            !memcmp(profiles[row].hash, hash, sizeof(hash)))
            return profiles[row].id;
    }
    return 0;
}

unsigned int zl_preflight(const struct zero_params *p)
{
    const uint8_t *head;
    const void *parts[ZL_PROFILE_PARTS];
    uint32_t lengths[ZL_PROFILE_PARTS], seen = 0, n, i;

    if ((uintptr_t)p != ZL_HDR_ADDR+2048 || p->magic != ZP_MAGIC || p->version != ZP_VERSION ||
        p->size != sizeof(*p) || p->flags != ZP_FLAG_CARD || p->dram_mib != 1024 ||
        p->monitor != 0x48000000 || p->uboot != 0x4a000000 ||
        p->dtb != 0x4a200000 || p->dtbo != 0x4a100000 ||
        p->toc1_head != 0x42e00000 || p->toc1_head_len < 64 || p->toc1_head_len > 64+16*368 ||
        p->bootimg_hdr != ZL_HDR_ADDR || p->kernel_gz != ZL_KGZ_ADDR ||
        p->ramdisk != 0x42000000 || p->kernel_addr != 0x40080000 ||
        p->kernel_gz_len > ZL_KGZ_MAX || p->ramdisk_len > 0x100000 ||
        p->dtb_len > ZL_FDT_MAX || p->dtbo_len > 0x100000)
        return 0;
    head = (const void *)(uintptr_t)p->toc1_head;
    n = le32(head+32);
    if (memcmp(head, "sunxi-package", 13) || !n || n > 16 ||
        p->toc1_head_len != 64+n*368 || le32(head+36) != p->toc1_len)
        return 0;
    parts[0] = head; lengths[0] = p->toc1_head_len;
    parts[1] = (const void *)(uintptr_t)p->monitor; lengths[1] = 0;
    parts[2] = (const void *)(uintptr_t)p->uboot; lengths[2] = 0;
    parts[3] = (const void *)(uintptr_t)p->dtb; lengths[3] = p->dtb_len;
    parts[4] = (const void *)(uintptr_t)p->dtbo; lengths[4] = p->dtbo_len;
    parts[5] = (const void *)(uintptr_t)p->bootimg_hdr; lengths[5] = 2048;
    parts[6] = (const void *)(uintptr_t)p->kernel_gz; lengths[6] = p->kernel_gz_len;
    parts[7] = (const void *)(uintptr_t)p->ramdisk; lengths[7] = p->ramdisk_len;
    for (i = 0; i < n; i++) {
        const uint8_t *item = head+64+i*368;
        uint32_t offset = le32(item+64), len = le32(item+68), bit = 0, slot = 0;
        if (offset > p->toc1_len || len > p->toc1_len-offset || (offset & 511))
            return 0;
        if (!memcmp(item, "monitor\0", 8)) { bit = 1; slot = 1; }
        else if (!memcmp(item, "u-boot\0", 7)) { bit = 2; slot = 2; }
        if (bit) {
            if ((seen & bit) || !len || len > 0x100000)
                return 0;
            seen |= bit;
            lengths[slot] = len;
        }
    }
    if (seen != 3)
        return 0;
    return zl_profile_match(parts, lengths, p->dram_mib);
}
