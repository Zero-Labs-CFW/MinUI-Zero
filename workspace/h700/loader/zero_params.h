/* SPDX-License-Identifier: GPL-2.0+ */
/*
 * MinUI Zero H700 stage 2 (2026-11-06): what the SPL hands our DRAM loader. The SPL jumps to the loader's entry at
 * EL3 (AArch64, MMU and caches off) with x0 pointing at this block, in DRAM. Every address is physical. The same
 * header is compiled into the SPL (arch/arm/mach-sunxi/zero_params.h) and into the loader: keep them identical.
 */
#ifndef ZERO_PARAMS_H
#define ZERO_PARAMS_H

#define ZP_MAGIC	0x5a504152u	/* "ZPAR" */
#define ZP_VERSION	2u
#define ZL_IMAGE_VERSION 2u

/* DRAM map shared by the SPL and the loader (1 GiB from 0x40000000; the SPL's own heap, BSS and page tables sit at
 * 0x4f000000 and up and die with it) */
#define ZL_LOAD_ADDR	0x4c000000ull	/* loader image (64-byte header first), 1 MiB region incl. its stack */
#define ZL_LOAD_MAX	0x00100000ull
#define ZL_KGZ_ADDR	0x45000000ull	/* compressed kernel as stored in boot.img (vendor U-Boot's own boot.img address) */
#define ZL_KGZ_MAX	0x02000000ull	/* 32 MiB */
#define ZL_FDT_MAX	0x00080000ull	/* room the loader has to grow the package dtb (built in place at its load address) */
#define ZL_HDR_ADDR	0x44f00000ull	/* the 2048-byte boot.img header */

/* loader image header (64 bytes, at ZL_LOAD_ADDR); the SPL refuses the loader unless magic, length and sum match */
#define ZL_HDR_MAGIC	"ZEROLDR1"	/* 8 bytes */
#define ZL_HDR_LEN	64
#define ZL_SUM_STAMP	0x5f0a6c39u	/* the sum field counts as this, like eGON */
struct zero_loader_hdr {
	char magic[8];
	unsigned int length;		/* whole image incl. this header, multiple of 512, <= ZL_LOAD_MAX - 64 KiB */
	unsigned int entry;		/* offset of the entry point from the image start (64) */
	unsigned int sum;		/* sum of every 32-bit word of the image, this field read as ZL_SUM_STAMP */
	unsigned int version;		/* ZL_IMAGE_VERSION */
	unsigned int preflight;		/* image-relative C-ABI entry; returns profile ID or 0, no writes/MMIO */
	unsigned int reserved[9];
};

#define ZP_FLAG_CARD	(1u << 0)	/* booted from the card (not FEL) */
#define ZP_PROFILE_SHIFT 8
#define ZP_PROFILE_PLUS  (1u << ZP_PROFILE_SHIFT)
#define ZP_PROFILE_H     (2u << ZP_PROFILE_SHIFT)
#define ZP_PROFILE_MASK  (255u << ZP_PROFILE_SHIFT)

struct zero_params {
	unsigned int magic;
	unsigned int version;
	unsigned int size;		/* sizeof(struct zero_params) */
	unsigned int flags;		/* ZP_FLAG_* */
	unsigned long long monitor;	/* vendor monitor run address; its head: +0x14 entry, +0x24 block, +0x30 words, +0xb0 fdt */
	unsigned long long uboot;	/* vendor U-Boot loaded at 0x4a000000, intact until preflight returns */
	unsigned long long dtb, dtb_len;	/* package dtb as read (raw bytes, at the address where the FDT is also built) */
	unsigned long long dtbo, dtbo_len;	/* package dtbo as read, dtbo_len 0 if none */
	unsigned long long bootimg_hdr;		/* the 2048-byte boot.img header */
	unsigned long long kernel_gz, kernel_gz_len;	/* compressed kernel exactly as stored */
	unsigned long long ramdisk, ramdisk_len;	/* ramdisk as stored (the Zero image ships a 512-byte dummy) */
	unsigned long long kernel_addr;	/* inflate to here (boot.img kernel_addr) */
	unsigned long long kernel_max;	/* room there */
	unsigned long long fdt_max;	/* room to grow the dtb in place */
	unsigned int dram_mib;
	unsigned int toc1_len;
	unsigned int dram_words[32];	/* stock boot0 +0x38, the trained values the monitor needs for resume */
	unsigned char board_block[8];	/* stock boot0 +0xf0 */
	unsigned int spl_us[4];		/* SPL timing, microseconds since reset: start, DRAM up, card ready, all reads done */
	unsigned int card_khz;
	unsigned int bus_width;
	unsigned int pmic_boot_regs;	/* AXP2202 reg 0x20 | reg 0x00 << 8 | reg 0xf0 << 16; all reads succeeded */
	unsigned long long toc1_head, toc1_head_len; /* original TOC1 header/table, before vendor fixups */
};

#endif
