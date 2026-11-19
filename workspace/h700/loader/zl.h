/* SPDX-License-Identifier: GPL-2.0+ */
/* MinUI Zero loader: what the loader's own files share. */
#ifndef ZL_H
#define ZL_H

#include <stddef.h>
#include <stdint.h>
#include "zero_params.h"

/* DRAM: 1 GiB block mapped normal cacheable by start.S; /memory starts here */
#define ZL_DRAM_BASE	0x40000000UL

/* cache.S */
void __asm_flush_dcache_all(void);
void __asm_invalidate_icache_all(void);
void __asm_invalidate_tlb_all(void);
void flush_dcache_range(unsigned long start, unsigned long end);
void dcache_disable(void);

/* start.S: caches off, RVBAR = monitor, warm reset into AArch64 at EL3; never returns */
void zl_enter_monitor(unsigned long monitor, unsigned long rvbar_reg) __attribute__((noreturn));

/* wdt.c */
void zl_wdog_policy(void);
void zl_reset_now(void) __attribute__((noreturn));

/* gunzip.c: 0 = inflated, CRC-32 and ISIZE checked; *out_len = bytes written */
int zl_gunzip(void *dst, unsigned long dst_max, const void *src, unsigned long src_len, unsigned long *out_len);

/* fixup.c */
int zl_build_fdt(const struct zero_params *p);
int zl_fixup_fdt(void *fdt, const struct zero_params *p);
int zl_snum(char *out, size_t max, const uint32_t sid[4]);
const char *zl_boot_reason(uint32_t regs);

/* main.c */
#ifndef ZL_HOST_TEST
void main(struct zero_params *p) __attribute__((noreturn));
#endif

#endif
