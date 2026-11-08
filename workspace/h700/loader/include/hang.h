/* SPDX-License-Identifier: GPL-2.0+ */
/* MinUI Zero loader: zlib/zutil.c includes <hang.h> for its DEBUG-only z_error(); DEBUG is never defined here. */
#ifndef ZL_HANG_H
#define ZL_HANG_H

void hang(void) __attribute__((noreturn));

#endif
