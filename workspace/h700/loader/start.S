/* SPDX-License-Identifier: GPL-2.0+ */
/*
 * MinUI Zero loader: image header, entry, MMU, and the final jump into the vendor monitor.
 *
 * The SPL enters at ZL_LOAD_ADDR + 64 at EL3, AArch64, MMU and caches off (zero_params.h), x0 = struct zero_params *.
 *
 * Translation (EL3 stage 1, identity map): one level-1 table, four 1 GiB block descriptors, 4 KiB granule, T0SZ 32
 * (a 4 GiB space; with a 4 KiB granule and T0SZ 25..33 the walk starts at level 1, the same choice as U-Boot's
 * cache_v8.c "if (va_bits < 39) level = 1"). Encodings cross-checked against U-Boot v2026.10
 * arch/arm/include/asm/armv8/mmu.h and arch/arm/cpu/armv8/cache_v8.c (get_tcr, add_map, mmu_setup); the attributes
 * per region are the ones U-Boot's sunxi_mem_map uses (arch/arm/mach-sunxi/board.c:48-67) and zero_vendor.c's
 * zv_mem_map runs on this SoC at EL3:
 *   [0, 1G)   device nGnRnE: SRAM, MMIO (RTC, watchdog, SID, SRAMC, RVBAR); execute-never
 *   [1G, 2G)  normal write-back cacheable, inner shareable: the 1 GiB of DRAM
 *   [2G, 4G)  device nGnRnE, execute-never (no DRAM there on the Plus)
 */

/* MAIR_EL3: U-Boot's MEMORY_ATTRIBUTES (mmu.h:34-38), one byte per AttrIndx */
#define MT_DEVICE_NGNRNE	0	/* attr 0x00: Device-nGnRnE */
#define MT_DEVICE_NGNRE		1	/* attr 0x04: Device-nGnRE */
#define MT_DEVICE_GRE		2	/* attr 0x0c: Device-GRE */
#define MT_NORMAL_NC		3	/* attr 0x44: Normal, inner/outer non-cacheable */
#define MT_NORMAL		4	/* attr 0xff: Normal, inner/outer write-back, read/write-allocate */
#define ZL_MAIR			0x000000ff440c0400

/* block descriptor bits (mmu.h:45-69) */
#define PTE_TYPE_BLOCK		(1 << 0)	/* bits 1:0 = 01: block (a 1 GiB block at level 1) */
#define PTE_BLOCK_MEMTYPE(x)	((x) << 2)	/* bits 4:2: AttrIndx into MAIR */
						/* bit 5 NS = 0: secure physical space (we are EL3, secure) */
						/* bits 7:6 AP = 00: read/write at EL3 (as U-Boot leaves it) */
#define PTE_BLOCK_NON_SHARE	(0 << 8)	/* bits 9:8 SH */
#define PTE_BLOCK_INNER_SHARE	(3 << 8)
#define PTE_BLOCK_AF		(1 << 10)	/* access flag set: no access-flag fault on first use */
						/* bit 11 nG = 0: global */
#define PTE_BLOCK_XN		(1 << 54)	/* in the EL3 regime bit 54 is XN (mmu.h names it UXN) */

#define ZL_BLK_DEVICE		(PTE_TYPE_BLOCK | PTE_BLOCK_MEMTYPE(MT_DEVICE_NGNRNE) | PTE_BLOCK_NON_SHARE | \
				 PTE_BLOCK_AF | PTE_BLOCK_XN)
#define ZL_BLK_NORMAL		(PTE_TYPE_BLOCK | PTE_BLOCK_MEMTYPE(MT_NORMAL) | PTE_BLOCK_INNER_SHARE | PTE_BLOCK_AF)

/*
 * TCR_EL3 (mmu.h:85-106; cache_v8.c get_tcr: EL3 = TCR_EL3_RSVD | ips << 16 | TG0_4K | SHARED_INNER | ORGN_WBWA |
 * IRGN_WBWA | T0SZ(va_bits), ips 0 and va_bits 32 when nothing is mapped above 4 GiB):
 *   bits 5:0   T0SZ  = 32       (64 - 32: 4 GiB of VA)
 *   bits 9:8   IRGN0 = 01       table walks inner write-back, write-allocate
 *   bits 11:10 ORGN0 = 01       table walks outer write-back, write-allocate
 *   bits 13:12 SH0   = 11       table walks inner shareable
 *   bits 15:14 TG0   = 00       4 KiB granule
 *   bits 18:16 PS    = 000      32-bit physical addresses
 *   bit 23, bit 31   RES1       (TCR_EL3_RSVD)
 */
#define ZL_TCR			((1 << 31) | (1 << 23) | (0 << 16) | (0 << 14) | (3 << 12) | (1 << 10) | \
				 (1 << 8) | 32)

/* SCTLR_EL3 bits (asm/system.h CR_M/CR_C/CR_I; WXN and A from the ARMv8 ARM) */
#define SCTLR_M			(1 << 0)	/* MMU on */
#define SCTLR_A			(1 << 1)	/* alignment fault checking: cleared, normal memory may be unaligned */
#define SCTLR_C			(1 << 2)	/* data cache on */
#define SCTLR_I			(1 << 12)	/* instruction cache on */
#define SCTLR_WXN		(1 << 19)	/* writable implies XN: cleared, the code runs from writable DRAM */

#define ENTRY(name)	.globl name; .type name, %function; .balign 4; name:
#define ENDPROC(name)	.size name, . - name

/* the 64-byte image header (struct zero_loader_hdr); tools/mkloader.py fills length and sum */
	.section .zl_header, "a"
	.ascii	"ZEROLDR1"		/* magic */
	.word	0			/* length: filled by mkloader.py */
	.word	64			/* entry: offset of _start */
	.word	0			/* sum: filled by mkloader.py */
	.word	2			/* image format, not the params ABI */
	.word	zl_preflight - 0x4c000000 /* C-ABI preflight while SPL stack/cache still live */
	.fill	9, 4, 0		/* reserved */

	.section .text.entry, "ax"
ENTRY(_start)
	mov	x19, x0			/* struct zero_params *: kept in x19 (the cache routines leave x18-x29 alone) */

	/* our own exception vectors first (zl_vectors below): the SPL installs none, VBAR_EL3 is still UNKNOWN */
	adrp	x0, zl_vectors
	add	x0, x0, #:lo12:zl_vectors
	msr	vbar_el3, x0
	isb

	/*
	 * Caches and TLB to a known state before the first translated access. dcache_disable writes back anything the SPL
	 * left dirty (the contract says it flushed: then this finds nothing), turns C and M off if they were on, and
	 * invalidates the EL3 TLB. No stack and no memory writes until the MMU is on, so nothing can be lost here.
	 */
	bl	dcache_disable
	bl	__asm_invalidate_icache_all

	ldr	x0, =ZL_MAIR
	msr	mair_el3, x0
	ldr	x0, =ZL_TCR
	msr	tcr_el3, x0
	adrp	x0, zl_ttb
	add	x0, x0, #:lo12:zl_ttb
	msr	ttbr0_el3, x0
	isb

	mrs	x0, sctlr_el3
	mov	x1, #(SCTLR_M | SCTLR_C)
	orr	x1, x1, #SCTLR_I
	orr	x0, x0, x1
	mov	x1, #SCTLR_A
	orr	x1, x1, #SCTLR_WXN
	bic	x0, x0, x1
	dsb	sy
	msr	sctlr_el3, x0
	isb

	/* stack (16-byte aligned top, grows down) and BSS, with the caches on */
	ldr	x0, =__stack_top
	mov	sp, x0
	adrp	x0, __bss_start
	add	x0, x0, #:lo12:__bss_start
	adrp	x1, __bss_end
	add	x1, x1, #:lo12:__bss_end
1:	cmp	x0, x1
	b.hs	2f
	stp	xzr, xzr, [x0], #16	/* link.ld keeps both ends 16-byte aligned */
	b	1b
2:
	mov	x0, x19
	bl	main
	b	zl_reset_now		/* main does not return; if it ever did, reset into the safety net */
ENDPROC(_start)

/*
 * void zl_enter_monitor(unsigned long monitor, unsigned long rvbar_reg)
 *
 * As zero_vendor.c ends: caches cleaned and off, I-cache invalidated, RVBAR (64-bit: low word = monitor, high word 0)
 * pointed at the monitor, then RMR_EL3 = AA64 (bit 0) | RR (bit 1): a warm reset of this core into AArch64 EL3 at
 * RVBAR. The RTC, the watchdog and DRAM contents survive it. Never returns.
 */
ENTRY(zl_enter_monitor)
	mov	x20, x0			/* monitor */
	mov	x21, x1			/* RVBAR backing register */
	bl	dcache_disable
	bl	__asm_invalidate_icache_all
	str	w20, [x21]
	str	wzr, [x21, #4]
	dsb	sy
	isb
	mov	x0, #3
	msr	rmr_el3, x0
	isb
3:	wfi
	b	3b
ENDPROC(zl_enter_monitor)

	.ltorg

/* the level-1 table: 4 entries of 1 GiB (32 bytes; 4 KiB alignment covers any TTBR0 alignment rule) */
	.section .rodata.zl_ttb, "a"
	.balign	4096
zl_ttb:
	.quad	0x00000000 | ZL_BLK_DEVICE	/* [0, 1G) */
	.quad	0x40000000 | ZL_BLK_NORMAL	/* [1G, 2G) DRAM */
	.quad	0x80000000 | ZL_BLK_DEVICE	/* [2G, 3G) */
	.quad	0xc0000000 | ZL_BLK_DEVICE	/* [3G, 4G) */
	.size	zl_ttb, . - zl_ttb

/*
 * EL3 exception vectors (verify-loader.md, 2026-11-06). The SPL installs none (CONFIG_ARMV8_SPL_EXCEPTION_VECTORS is
 * off, ../u-boot-build/.config:304; arch/arm/cpu/armv8/start.S:107), so VBAR_EL3 keeps its UNKNOWN reset value: an
 * exception would branch into whatever is there (in [0, 1G) the map above makes it device + execute-never, which
 * faults again on every fetch) and spin until the SPL's 8 s watchdog fires, or forever once zl_wdog_policy has
 * disarmed it. Every entry instead marks RTC GP15 =
 * 0x5a56004c | ESR_EL3.EC << 8 (ZL_FAIL_EXCEPTION, rtc.h; never 0 and never 0x5a56ffff) and resets in 0.5 s like
 * zl_reset_now (wdt.c: WDOG0 0x030090a0, cfg +0x14 = 1, mode +0x18 = 0.5 s | enable, ctl +0x10 = 0x14af), so the SPL's
 * safety net runs and GP14 shows the cause on the next start. No stack and no memory but the two MMIO blocks, which
 * are reachable with the MMU on (identity, device) or off.
 */
	.section .zl_vectors, "ax"	/* its own output section in link.ld */
	.balign	2048			/* VBAR_EL3 bits 10:0 are RES0 */
zl_vectors:
	.rept	16
	.balign	128
	b	zl_exception
	.endr
zl_exception:
	mrs	x2, esr_el3
	ubfx	w2, w2, #26, #6		/* EC */
	movz	w1, #0x004c
	movk	w1, #0x5a56, lsl #16
	orr	w1, w1, w2, lsl #8
	movz	x0, #0x013c
	movk	x0, #0x0700, lsl #16	/* RTC GP15 0x0700013c */
	str	w1, [x0]
	movz	x0, #0x90a0
	movk	x0, #0x0300, lsl #16	/* WDOG0 0x030090a0 */
	mov	w1, #1
	str	w1, [x0, #0x14]		/* cfg: whole-system reset */
	str	w1, [x0, #0x18]		/* mode: interval 0 (0.5 s) | enable */
	movz	w1, #0x14af
	str	w1, [x0, #0x10]		/* ctl: key 0xa57 << 1 | restart */
	dsb	sy
4:	b	4b
