/* SPDX-License-Identifier: GPL-2.0+ */
/*
 * MinUI Zero loader: stand-in for U-Boot's include/compiler.h, which zlib/zlib.c includes first. The copied zlib needs
 * two things from it: the fixed-width types (uintptr_t, zlib/inffast.c:89) and IS_ENABLED() for
 * "#if IS_ENABLED(CONFIG_ZLIB_UNCOMPRESS)" (zlib/zlib.c:33); the loader does not build uncompr.c, so every option
 * reads as off.
 */
#ifndef ZL_COMPILER_H
#define ZL_COMPILER_H

#include <stddef.h>
#include <stdint.h>

#define IS_ENABLED(option)	0

#endif
