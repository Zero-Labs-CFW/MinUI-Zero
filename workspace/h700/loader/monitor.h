/* SPDX-License-Identifier: GPL-2.0+ */
#ifndef ZL_MONITOR_H
#define ZL_MONITOR_H
#include "zero_params.h"
#include <stddef.h>
#include <stdint.h>

#define ZL_MONITOR_ADDR 0x48000000ull
#define ZL_MONITOR_RESERVE 0x1000000ull
#define ZL_STUB_ADDR 0x4a000000ull
#define ZL_STUB_SIZE 80u

int zl_prepare_monitor(void *head, size_t head_len, void *stub, size_t stub_len,
                       const struct zero_params *p);
int zl_params_ok_at(const struct zero_params *p, uint64_t params_addr);
int zl_image_ok(const void *image, uint64_t load_addr, uint64_t max, unsigned long out_len);

#endif
