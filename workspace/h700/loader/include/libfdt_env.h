/* SPDX-License-Identifier: GPL-2.0+ */
/*
 * MinUI Zero loader: the libfdt environment. Replaces scripts/dtc/libfdt/libfdt_env.h (same include guard, so the
 * upstream one is never pulled in: it wants a hosted libc). Fixed-width types from the compiler's own freestanding
 * headers, big-endian conversion by compiler byte-swap builtins (the loader is little-endian only), and the string
 * functions from lib/string.c (bare metal) or the host libc (test/). Cross-checked against U-Boot's
 * include/linux/libfdt_env.h, which maps the same names onto be32_to_cpu etc. and strtoul onto simple_strtoul.
 */
#ifndef LIBFDT_ENV_H
#define LIBFDT_ENV_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>	/* strtoul (fdt_overlay.c) */
#include <string.h>	/* mem*, strlen, strnlen, strchr, strrchr */
#include <limits.h>	/* INT_MAX */

#if __BYTE_ORDER__ != __ORDER_LITTLE_ENDIAN__
#error "the loader is little-endian only"
#endif

#define FDT_FORCE
#define FDT_BITWISE

typedef uint16_t fdt16_t;
typedef uint32_t fdt32_t;
typedef uint64_t fdt64_t;

static inline uint16_t fdt16_to_cpu(fdt16_t x)
{
	return __builtin_bswap16(x);
}

static inline fdt16_t cpu_to_fdt16(uint16_t x)
{
	return __builtin_bswap16(x);
}

static inline uint32_t fdt32_to_cpu(fdt32_t x)
{
	return __builtin_bswap32(x);
}

static inline fdt32_t cpu_to_fdt32(uint32_t x)
{
	return __builtin_bswap32(x);
}

static inline uint64_t fdt64_to_cpu(fdt64_t x)
{
	return __builtin_bswap64(x);
}

static inline fdt64_t cpu_to_fdt64(uint64_t x)
{
	return __builtin_bswap64(x);
}

#endif /* LIBFDT_ENV_H */
