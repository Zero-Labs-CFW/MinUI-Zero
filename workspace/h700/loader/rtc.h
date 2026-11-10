/* SPDX-License-Identifier: GPL-2.0+ */
/*
 * MinUI Zero loader: MMIO helpers, RTC progress marks and boot-time stamps.
 *
 * The RTC general-purpose registers (GP0..GP15 at 0x07000100 + 4n) live in the always-on RTC domain: they survive the
 * watchdog reset and the warm reset into the monitor, so Linux (or the next SPL start) can read where this boot got to.
 * GP15 is the SPL's attempt marker (zero_vendor.c ZV_RTC_GP15: nonzero = this attempt is not acknowledged yet); the
 * loader only ever writes 0x5a5600xx there, never 0 and never the restore code 0x5a56ffff, so the safety net keeps
 * working. The stage 1 SPL steps in GP15 are 1..0x21 (zv_status, ZV_TRACE); the loader's are 0x41..0x4f.
 */
#ifndef ZL_RTC_H
#define ZL_RTC_H

#include <stdint.h>
#include "panel_policy.h"

#ifdef ZL_HOST_TEST
void write32(unsigned long addr, uint32_t val);
uint32_t read32(unsigned long addr);
uint64_t zl_test_counter(void);
#else
static inline void write32(unsigned long addr, uint32_t val)
{
	*(volatile uint32_t *)addr = val;
}

static inline uint32_t read32(unsigned long addr)
{
	return *(volatile uint32_t *)addr;
}
#endif

#define ZL_RTC_BASE	0x07000000UL
#define ZL_RTC_GP(n)	(ZL_RTC_BASE + 0x100 + 4 * (n))
#define ZL_RTC_GP0	ZL_RTC_GP(0)	/* 0x07000100: stamp, just before the hand-off */
#define ZL_RTC_GP4	ZL_RTC_GP(4)	/* 0x07000110: stamp, kernel inflated (overwrites the SPL's card-clock note) */
#define ZL_RTC_GP5	ZL_RTC_GP(5)	/* 0x07000114: test-kit try budget, 0x5d0000NN (h-ramoops/gp-mark.sh) */
#define ZL_RTC_GP15	ZL_RTC_GP(15)	/* 0x0700013c: progress mark / SPL attempt marker */

/* progress marks: GP15 = ZL_MARK_BASE | step */
#define ZL_MARK_BASE		0x5a560000u
#define ZL_MARK_MAIN		0x41	/* main() entered */
#define ZL_MARK_GUNZIP		0x42	/* kernel inflated and checked */
#define ZL_MARK_FDT		0x43	/* kernel FDT built, packed and cleaned to DRAM */
#define ZL_MARK_MONITOR		0x44	/* monitor head filled */
#define ZL_MARK_HANDOFF		0x45	/* caches going off, RMR into the monitor next */
#define ZL_FAIL_EXCEPTION	0x4c	/* EL3 exception (start.S zl_vectors); GP15 bits 15:8 = ESR_EL3.EC */
#define ZL_FAIL_PARAMS		0x4d	/* parameter block or a region in it rejected (addition to the brief) */
#define ZL_FAIL_GUNZIP		0x4e	/* inflate, CRC-32/ISIZE or arm64 Image header check failed */
#define ZL_FAIL_FDT		0x4f	/* FDT open, fixup or pack failed */

void zl_mark(uint32_t step);
uint64_t zl_counter(void);
void zl_stamp(unsigned long reg);
void zl_sid_read(uint32_t sid[4]);
int zl_lcd_begin(void);
const char *zl_lcd_type(void);
const char *zl_lcd_type_rule(enum zl_panel_rule rule);
int zl_prepare_hardware(void);

#endif
