/* SPDX-License-Identifier: GPL-2.0+ */
/* MinUI Zero loader: the limits libfdt and lib/string.c use, from the compiler's predefined macros. Bare metal only. */
#ifndef ZL_LIMITS_H
#define ZL_LIMITS_H

#define CHAR_BIT	__CHAR_BIT__
#define INT_MAX		__INT_MAX__
#define INT_MIN		(-INT_MAX - 1)
#define UINT_MAX	(INT_MAX * 2U + 1U)
#define LONG_MAX	__LONG_MAX__
#define ULONG_MAX	(LONG_MAX * 2UL + 1UL)

#endif
