/* SPDX-License-Identifier: GPL-2.0+ */
/* MinUI Zero loader: strtoul for libfdt's fdt_overlay.c (lib/string.c). Bare-metal build only. */
#ifndef ZL_STDLIB_H
#define ZL_STDLIB_H

#include <stddef.h>

unsigned long strtoul(const char *nptr, char **endptr, int base);

#endif
