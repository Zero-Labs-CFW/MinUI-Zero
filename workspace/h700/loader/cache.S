/* SPDX-License-Identifier: GPL-2.0+ */
/*
 * MinUI Zero loader: cache and TLB maintenance at EL3.
 *
 * __asm_dcache_level, __asm_dcache_all, __asm_flush_dcache_all and __asm_invalidate_icache_all are copied from U-Boot
 * v2026.10 arch/arm/cpu/armv8/cache.S ((C) Copyright 2013 David Feng <fenghua@phytium.com.cn>, based on sample code
 * from the ARMv8 ARM), unchanged but for the ENTRY/ENDPROC macros. __asm_invalidate_tlb_all is the EL3 branch of
 * arch/arm/cpu/armv8/tlb.S (the loader only runs at EL3). flush_dcache_range and dcache_disable are ours.
 *
 * Register use (callers rely on it): x0-x16 and lr may be clobbered; x17 is used by dcache_disable to keep its return
 * address; x18-x30 (but lr) are never touched.
 */

#define ENTRY(name)	.globl name; .type name, %function; .balign 4; name:
#define ENDPROC(name)	.size name, . - name

/*
 * void __asm_dcache_level(level)
 *
 * flush or invalidate one level cache.
 *
 * x0: cache level
 * x1: 0 clean & invalidate, 1 invalidate only
 * x16: FEAT_CCIDX
 * x2~x9: clobbered
 */
.pushsection .text.__asm_dcache_level, "ax"
ENTRY(__asm_dcache_level)
	lsl	x12, x0, #1
	msr	csselr_el1, x12		/* select cache level */
	isb				/* sync change of cssidr_el1 */
	mrs	x6, ccsidr_el1		/* read the new cssidr_el1 */
	ubfx	x2, x6,  #0,  #3	/* x2 <- log2(cache line size)-4 */
	cbz	x16, 3f			/* check for FEAT_CCIDX */
	ubfx	x3, x6,  #3, #21	/* x3 <- number of cache ways - 1 */
	ubfx	x4, x6, #32, #24	/* x4 <- number of cache sets - 1 */
	b	4f
3:
	ubfx	x3, x6,  #3, #10	/* x3 <- number of cache ways - 1 */
	ubfx	x4, x6, #13, #15	/* x4 <- number of cache sets - 1 */
4:
	add	x2, x2, #4		/* x2 <- log2(cache line size) */
	clz	w5, w3			/* bit position of #ways */
	/* x12 <- cache level << 1 */
	/* x2 <- line length offset */
	/* x3 <- number of cache ways - 1 */
	/* x4 <- number of cache sets - 1 */
	/* x5 <- bit position of #ways */

loop_set:
	mov	x6, x3			/* x6 <- working copy of #ways */
loop_way:
	lsl	x7, x6, x5
	orr	x9, x12, x7		/* map way and level to cisw value */
	lsl	x7, x4, x2
	orr	x9, x9, x7		/* map set number to cisw value */
	tbz	w1, #0, 1f
	dc	isw, x9
	b	2f
1:	dc	cisw, x9		/* clean & invalidate by set/way */
2:	subs	x6, x6, #1		/* decrement the way */
	b.ge	loop_way
	subs	x4, x4, #1		/* decrement the set */
	b.ge	loop_set

	ret
ENDPROC(__asm_dcache_level)
.popsection

/*
 * void __asm_flush_dcache_all(int invalidate_only)
 *
 * x0: 0 clean & invalidate, 1 invalidate only
 *
 * flush or invalidate all data cache by SET/WAY.
 */
.pushsection .text.__asm_dcache_all, "ax"
ENTRY(__asm_dcache_all)
	mov	x1, x0
	dsb	sy
	mrs	x10, clidr_el1		/* read clidr_el1 */
	ubfx	x11, x10, #24, #3	/* x11 <- loc */
	cbz	x11, finished		/* if loc is 0, exit */
	mov	x15, lr
	mrs	x16, s3_0_c0_c7_2	/* read value of id_aa64mmfr2_el1*/
	ubfx	x16, x16, #20, #4	/* save FEAT_CCIDX identifier in x16 */
	mov	x0, #0			/* start flush at cache level 0 */
	/* x0  <- cache level */
	/* x10 <- clidr_el1 */
	/* x11 <- loc */
	/* x15 <- return address */

loop_level:
	add	x12, x0, x0, lsl #1	/* x12 <- tripled cache level */
	lsr	x12, x10, x12
	and	x12, x12, #7		/* x12 <- cache type */
	cmp	x12, #2
	b.lt	skip			/* skip if no cache or icache */
	bl	__asm_dcache_level	/* x1 = 0 flush, 1 invalidate */
skip:
	add	x0, x0, #1		/* increment cache level */
	cmp	x11, x0
	b.gt	loop_level

	mov	x0, #0
	msr	csselr_el1, x0		/* restore csselr_el1 */
	dsb	sy
	isb
	mov	lr, x15

finished:
	ret
ENDPROC(__asm_dcache_all)
.popsection

.pushsection .text.__asm_flush_dcache_all, "ax"
ENTRY(__asm_flush_dcache_all)
	mov	x0, #0
	b	__asm_dcache_all
ENDPROC(__asm_flush_dcache_all)
.popsection

/*
 * void __asm_invalidate_icache_all(void)
 *
 * invalidate all tlb entries.
 */
.pushsection .text.__asm_invalidate_icache_all, "ax"
ENTRY(__asm_invalidate_icache_all)
	ic	ialluis
	isb	sy
	ret
ENDPROC(__asm_invalidate_icache_all)
.popsection

/* void __asm_invalidate_tlb_all(void): every EL3 TLB entry (tlb.S, its EL3 branch) */
.pushsection .text.__asm_invalidate_tlb_all, "ax"
ENTRY(__asm_invalidate_tlb_all)
	tlbi	alle3
	dsb	sy
	isb
	ret
ENDPROC(__asm_invalidate_tlb_all)
.popsection

/*
 * void flush_dcache_range(unsigned long start, unsigned long end)
 *
 * Clean (dc cvac: write back, keep the line) every data cache line in [start, end) to the point of coherency, so a
 * reader with caches off sees it. Line size: the smallest D-cache line in the system, CTR_EL0.DminLine (bits 19:16,
 * log2 of the line size in 4-byte words), as U-Boot's __asm_flush_dcache_range, which uses dc civac instead.
 */
.pushsection .text.flush_dcache_range, "ax"
ENTRY(flush_dcache_range)
	mrs	x3, ctr_el0
	ubfx	x3, x3, #16, #4		/* DminLine */
	mov	x2, #4
	lsl	x2, x2, x3		/* x2 <- line size in bytes */
	sub	x3, x2, #1
	bic	x0, x0, x3		/* start down to a line boundary */
	cmp	x0, x1
	b.hs	2f
1:	dc	cvac, x0
	add	x0, x0, x2
	cmp	x0, x1
	b.lo	1b
2:	dsb	sy
	ret
ENDPROC(flush_dcache_range)
.popsection

/*
 * void dcache_disable(void)
 *
 * Every dirty line to DRAM, then SCTLR_EL3.C and .M off, then once more (whatever was allocated between the first
 * pass and the switch), then the TLB. The same sequence as zero_vendor.c's hand-off: flush_dcache_all() followed by
 * U-Boot's dcache_disable() (arch/arm/cpu/armv8/cache_v8.c: C|M off, then flush_dcache_all, then the TLB). Uses no
 * memory (the stack may already be uncached when it returns), keeps lr in x17.
 */
.pushsection .text.dcache_disable, "ax"
ENTRY(dcache_disable)
	mov	x17, lr
	bl	__asm_flush_dcache_all
	mrs	x0, sctlr_el3
	bic	x0, x0, #(1 << 2)	/* C: data and unified caches off */
	bic	x0, x0, #(1 << 0)	/* M: EL3 stage 1 translation off */
	dsb	sy
	msr	sctlr_el3, x0
	isb
	bl	__asm_flush_dcache_all
	bl	__asm_invalidate_tlb_all
	mov	lr, x17
	ret
ENDPROC(dcache_disable)
.popsection
