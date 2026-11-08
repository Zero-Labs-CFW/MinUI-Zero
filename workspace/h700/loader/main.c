// SPDX-License-Identifier: GPL-2.0+
/*
 * MinUI Zero H700 stage 2 loader (2026-11-06): replaces vendor U-Boot between our SPL and the vendor monitor.
 *
 * The SPL has loaded the vendor monitor, the package dtb (+dtbo), the boot.img header, the gzip kernel and the ramdisk
 * into DRAM and entered start.S at EL3 with x0 = struct zero_params (zero_params.h). Here: inflate the kernel, build
 * the kernel FDT, fill the monitor head, set the watchdog, and warm-reset into the monitor the way zero_vendor.c does.
 * The monitor enters the A32 stub, which issues the vendor kernel SMC with mode=1.
 * This registers the FDT for PSCI; the direct-kernel path does not (research-monitor.md).
 *
 * Any failure marks RTC GP15 and resets in 0.5 s: the SPL then sees an unacknowledged attempt and restores the
 * pinned stock boot0 (zero_vendor_early), the same safety net as stage 1.
 */
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <libfdt.h>
#include "zl.h"
#include "rtc.h"
#include "monitor.h"

_Static_assert(sizeof(struct zero_loader_hdr) == ZL_HDR_LEN, "zero_loader_hdr must be 64 bytes");

/*
 * RVBAR backing store, as zero_vendor.c (its hand-off) and boot0.h's rmr_switch: the die variant in SRAM_VER_REG
 * bits 7:0 (SUNXI_SRAMC_BASE 0x03000000, asm/arch-sunxi/cpu_sun50i_h6.h:10, + 0x24) picks the address. Values for the
 * H616 from U-Boot v2026.10 arch/arm/mach-sunxi/Kconfig: MACH_SUN50I_H616 selects SUN50I_GEN_H6 (line 549), so
 * SUNXI_RVBAR_ADDRESS = 0x09010040 (line 244) and SUNXI_RVBAR_ALTERNATIVE = 0x08100040 (line 256).
 */
#define ZL_SRAMC_VER		0x03000024UL
#define ZL_RVBAR_ADDRESS	0x09010040UL
#define ZL_RVBAR_ALTERNATIVE	0x08100040UL

/* vendor monitor head (zero_params.h, zero_vendor.c) */
#define ZL_MON_KERNEL	0x14	/* nonzero: the monitor enters this AArch64 kernel instead of U-Boot */
#define ZL_MON_BLOCK	0x24	/* stock boot0's 8-byte block (boot0 +0xf0) */
#define ZL_MON_WORDS	0x30	/* the 32 trained DRAM words (boot0 +0x38), needed for resume */
#define ZL_MON_FDT	0xb0	/* FDT address */
#define ZL_MON_SPAN	0x1000000UL	/* the package dtb's /memreserve/ 0x48000000 0x1000000 */

/* arm64 Image header (Linux Documentation/arm64/booting.txt) */
#define ZL_IMG_TEXT_OFFSET	8
#define ZL_IMG_SIZE		16
#define ZL_IMG_MAGIC		0x38
#define ZL_IMG_MAGIC_ARM64	0x644d5241u	/* "ARM\x64" */
#define ZL_2M			0x200000UL

/* the 1 GiB that start.S maps normal cacheable; every region the loader touches must be inside it */
#define ZL_MAP_END	(ZL_DRAM_BASE + 0x40000000UL)

static void __attribute__((noreturn)) zl_fail(uint32_t code)
{
	zl_mark(code);
	zl_reset_now();
}

static uint64_t zl_dram_end;

/* [addr, addr + len) inside DRAM and inside the cacheable window; an empty region (len 0) is not looked at */
static int zl_region_ok(uint64_t addr, uint64_t len)
{
	return !len || (addr >= ZL_DRAM_BASE && addr <= zl_dram_end && len <= zl_dram_end - addr);
}

static int zl_overlap(uint64_t a, uint64_t alen, uint64_t b, uint64_t blen)
{
	return alen && blen && a < b + blen && b < a + alen;
}

/*
 * The parameter block and every region in it: inside DRAM, and the regions that are written (kernel, FDT, the monitor
 * head, the stub) clear of everything else the hand-off needs, the loader itself included.
 */
int zl_params_ok_at(const struct zero_params *p, uint64_t params_addr)
{
	if (!p)
		return 0;
	struct { uint64_t a, n; } r[] = {
		{ ZL_LOAD_ADDR, ZL_LOAD_MAX },		/* 0: this loader, its BSS and stack */
		{ p->monitor, ZL_MON_SPAN },		/* 1 */
		{ p->dtb, p->fdt_max },			/* 2: the FDT grows in place up to fdt_max */
		{ p->dtbo, p->dtbo_len },		/* 3 */
		{ p->bootimg_hdr, 2048 },		/* 4 */
		{ p->kernel_gz, p->kernel_gz_len },	/* 5 */
		{ p->ramdisk, p->ramdisk_len },		/* 6 */
		{ p->kernel_addr, p->kernel_max },	/* 7: inflated kernel, its BSS included */
		{ params_addr, sizeof(*p) },	/* 8 */
		{ p->uboot, ZL_STUB_SIZE },	/* 9 */
	};
	const unsigned int nr = sizeof(r) / sizeof(r[0]), written[] = { 1, 2, 7, 9 };
	unsigned int i, j, w;

	if (p->magic != ZP_MAGIC || p->version != ZP_VERSION || p->size != sizeof(*p) || (params_addr & 7))
		return 0;
	if (!p->dram_mib || p->dram_mib > 1024)
		return 0;
	zl_dram_end = ZL_DRAM_BASE + ((uint64_t)p->dram_mib << 20);
	if (zl_dram_end > ZL_MAP_END)
		zl_dram_end = ZL_MAP_END;
	if (!p->dtb_len || !p->kernel_gz_len || !p->kernel_max || (p->dtb & 7) || (p->monitor & 3) ||
	    (p->uboot & 3) || p->monitor > UINT32_MAX || p->kernel_addr > UINT32_MAX || p->dtb > UINT32_MAX)
		return 0;	/* the monitor head holds 32-bit addresses */
	/* This is a Plus-only experiment: reject unqualified placement before any write. */
	if (p->monitor != ZL_MONITOR_ADDR || p->uboot != ZL_STUB_ADDR || p->dtb != 0x4a200000 ||
	    p->bootimg_hdr != ZL_HDR_ADDR || p->kernel_gz != ZL_KGZ_ADDR || p->kernel_addr != 0x40080000 ||
	    p->ramdisk != 0x42000000 || p->kernel_gz_len > ZL_KGZ_MAX ||
	    p->kernel_max > 0x42000000 - 0x40080000 || p->ramdisk_len > 0x100000 ||
	    p->dtb_len < 40 || p->dtb_len > p->fdt_max || p->fdt_max > ZL_FDT_MAX ||
	    p->dtbo_len > 0x100000 || (p->dtbo_len && p->dtbo != 0x4a100000))
		return 0;
	for (i = 0; i < nr; i++)
		if (!zl_region_ok(r[i].a, r[i].n))
			return 0;
	for (w = 0; w < sizeof(written) / sizeof(written[0]); w++) {
		i = written[w];
		if (i >= nr)
			continue;
		for (j = 0; j < nr; j++)
			if (j != i && zl_overlap(r[i].a, r[i].n, r[j].a, r[j].n))
				return 0;
	}
	return 1;
}

/* the inflated kernel is an arm64 Image placed text_offset above a 2 MiB boundary, and fits with its BSS */
int zl_image_ok(const void *image, uint64_t load_addr, uint64_t max, unsigned long out_len)
{
	const unsigned char *img = image;
	uint64_t text_offset, image_size;
	uint32_t magic;

	if (!img || out_len < 64 || out_len > max)
		return 0;
	memcpy(&magic, img + ZL_IMG_MAGIC, 4);
	memcpy(&text_offset, img + ZL_IMG_TEXT_OFFSET, 8);
	memcpy(&image_size, img + ZL_IMG_SIZE, 8);
	if (magic != ZL_IMG_MAGIC_ARM64 || load_addr < text_offset || (load_addr - text_offset) % ZL_2M)
		return 0;
	/* image_size 0: pre-3.17 kernel with no size; on the Plus 0x11cc000 for 0x113b008 bytes inflated */
	if (image_size && (image_size > max || out_len > image_size))
		return 0;
	return 1;
}

#ifndef ZL_HOST_TEST
void main(struct zero_params *p)
{
	unsigned long out_len, fdt, mon, rvbar;

	zl_mark(ZL_MARK_MAIN);
	if ((uintptr_t)p != ZL_HDR_ADDR + 2048 || !zl_params_ok_at(p, (uintptr_t)p))
		zl_fail(ZL_FAIL_PARAMS);
	/* Only the returning, read-only preflight may select an artifact profile. Both qualified
	 * rows use PE6 strap with pull; other panel rules remain refused until implemented/tested. */
	if ((p->flags & ZP_PROFILE_MASK) != ZP_PROFILE_PLUS &&
	    (p->flags & ZP_PROFILE_MASK) != ZP_PROFILE_H)
		zl_fail(ZL_FAIL_PARAMS);
	if (zl_prepare_hardware())
		zl_fail(ZL_FAIL_PARAMS);
	if (zl_lcd_begin())
		zl_fail(ZL_FAIL_PARAMS);

	/* 1. the kernel, inflated in place and checked (gzip CRC-32 + ISIZE inside zlib, then the Image header) */
	if (zl_gunzip((void *)(uintptr_t)p->kernel_addr, p->kernel_max, (const void *)(uintptr_t)p->kernel_gz,
		      p->kernel_gz_len, &out_len) ||
	    !zl_image_ok((const void *)(uintptr_t)p->kernel_addr, p->kernel_addr, p->kernel_max, out_len))
		zl_fail(ZL_FAIL_GUNZIP);
	zl_mark(ZL_MARK_GUNZIP);
	zl_stamp(ZL_RTC_GP4);

	/* 2. the kernel FDT, built where the SPL put the package dtb, then cleaned to DRAM */
	fdt = (unsigned long)p->dtb;
	if (zl_build_fdt(p))
		zl_fail(ZL_FAIL_FDT);
	flush_dcache_range(fdt, fdt + fdt_totalsize((const void *)fdt));
	zl_mark(ZL_MARK_FDT);

	/*
	 * 3. the monitor head. +0x30/+0x24 are what zero_vendor.c writes from the pinned stock boot0 (resume needs them);
	 * written again from the parameter block so the head is complete whichever side fills it (same values).
	 */
	mon = (unsigned long)p->monitor;
	if (zl_prepare_monitor((void *)mon, 0xb8, (void *)(uintptr_t)p->uboot, ZL_STUB_SIZE, p))
		zl_fail(ZL_FAIL_PARAMS);
	zl_mark(ZL_MARK_MONITOR);

	/* 4. watchdog: armed for a pending test try, else off (wdt.c) */
	zl_wdog_policy();

	/* 5. hand-off: caches cleaned and off (everything above reaches DRAM there), RVBAR = monitor, RMR */
	zl_stamp(ZL_RTC_GP0);
	zl_mark(ZL_MARK_HANDOFF);
	rvbar = (read32(ZL_SRAMC_VER) & 0xff) ? ZL_RVBAR_ALTERNATIVE : ZL_RVBAR_ADDRESS;
	zl_enter_monitor(mon, rvbar);
}
#endif
