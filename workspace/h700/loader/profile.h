/* SPDX-License-Identifier: GPL-2.0+ */
#ifndef ZL_PROFILE_H
#define ZL_PROFILE_H
#include <stdint.h>
#include "zero_params.h"
#define ZL_PROFILE_PARTS 8
/* header/table, monitor, U-Boot, DTB, DTBO, boot header, gzip, ramdisk. */
unsigned int zl_profile_match(const void *const parts[ZL_PROFILE_PARTS],
                             const uint32_t lengths[ZL_PROFILE_PARTS], uint32_t ram_mib);
unsigned int zl_preflight(const struct zero_params *p);
#endif
