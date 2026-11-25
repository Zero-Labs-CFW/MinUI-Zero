/* SPDX-License-Identifier: GPL-2.0+ */
/*
 * MinUI Zero loader: zlib/inflate.c calls schedule() (the U-Boot watchdog kick) at every deflate block. Deliberately a
 * no-op: the watchdog the SPL armed keeps running while the kernel inflates, so a hang here still resets into the
 * safety net. The loader's own watchdog policy (wdt.c, zl_wdog_policy) runs once, just before the hand-off.
 */
#ifndef ZL_WATCHDOG_H
#define ZL_WATCHDOG_H

static inline void schedule(void)
{
}

#endif
