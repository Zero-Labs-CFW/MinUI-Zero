// SPDX-License-Identifier: GPL-2.0+
/*
 * MinUI Zero loader: RTC progress marks, boot-time stamps, and the SID read the bootargs need. Everything here touches
 * hardware; test/soc_stub.c stands in for this file in the host test.
 */
#include "rtc.h"

void zl_mark(uint32_t step)
{
	write32(ZL_RTC_GP15, ZL_MARK_BASE | step);
}

/* the 24 MHz generic counter runs from reset (the SPL stamps and Linux's boot clock read the same one) */
uint64_t zl_counter(void)
{
#ifdef ZL_HOST_TEST
	return zl_test_counter();
#else
	uint64_t c;

	__asm__ volatile("isb; mrs %0, cntpct_el0" : "=r"(c));
	return c;
#endif
}

/* microseconds since reset into an RTC general-purpose register, as zero_vendor.c zv_stamp() does */
void zl_stamp(unsigned long reg)
{
	write32(reg, (uint32_t)(zl_counter() / 24));
}

/*
 * The four SID chip-id words. U-Boot reads them the same way on this SoC (arch/arm/mach-sunxi/cpu_info.c:167-171,
 * SUNXI_SID_BASE 0x03006200 for the H6/H616 family, asm/arch-sunxi/cpu_sun50i_h6.h:14).
 */
#define ZL_SID_BASE	0x03006200UL

void zl_sid_read(uint32_t sid[4])
{
	int i;

	for (i = 0; i < 4; i++)
		sid[i] = read32(ZL_SID_BASE + 4 * i);
}

/* Counter deadlines supply timing; the iteration ceiling only detects a stalled counter. */
static int zl_delay_since(uint64_t start, uint32_t us)
{
	uint64_t ticks = (uint64_t)us * 24;
#ifdef ZL_HOST_TEST
	const unsigned int limit = 1024;
#else
	const unsigned int limit = 1u << 26;
#endif
	for (unsigned int n = 0; n < limit; n++)
		if (zl_counter() - start >= ticks)
			return 0;
	return -1;
}

static int zl_delay_us(uint32_t us)
{
	return zl_delay_since(zl_counter(), us);
}

/* Plus vendor hand-off state, corrected by verify-uboot-effects.md D1/D2/D5.
 * Run only after entering DRAM: changing SRAM ownership while the SPL executes there is unsafe. */
int zl_prepare_hardware(void)
{
	static const unsigned long plls[] = {
		0x03001028, 0x03001040, 0x03001048, 0x03001050, 0x03001060,
	};
	uint32_t mode = read32(0x07000118);

	/* These requests belong to vendor recovery/EFEX/fastboot. Preserve the request for stock fallback. */
	if (mode == 0x5a || mode == 0x5c || mode == 0x5f || mode == 0x60)
		return -1;
	write32(0x07000118, 0);
	if (read32(0x07000118))
		return -1;
	for (unsigned int i = 0; i < sizeof(plls) / sizeof(plls[0]); i++)
		write32(plls[i], read32(plls[i]) | 0x80000000u);
	if (zl_delay_us(100))
		return -1;
	write32(0x03000000, read32(0x03000000) & 0x80000000u);
	write32(0x03000004, read32(0x03000004) & ~(1u << 24));
	write32(0x03001804, read32(0x03001804) | 1u);
	write32(0x0300170c, (read32(0x0300170c) | (1u << 16)) & ~1u);
	return 0;
}

static uint64_t lcd_reset_high_at;
static int lcd_started;

/* Keep the vendor's reset intervals; the final 100 ms can elapse during kernel inflate. */
int zl_lcd_begin(void)
{
	lcd_started = 0;
	/* Only PI14/PI15 are outputs here; SPI PI8..PI10 remain the kernel's responsibility. */
	write32(0x0300b124, (read32(0x0300b124) & ~0xff000000u) | 0x11000000u);
	write32(0x0300b130, read32(0x0300b130) | (1u << 15));
	if (zl_delay_us(30000))
		return -1;
	write32(0x0300b130, read32(0x0300b130) | (1u << 14));
	if (zl_delay_us(15000))
		return -1;
	write32(0x0300b130, read32(0x0300b130) & ~(1u << 14));
	if (zl_delay_us(50000))
		return -1;
	write32(0x0300b130, read32(0x0300b130) | (1u << 14));
#ifndef ZL_HOST_TEST
	__asm__ volatile("dsb sy" ::: "memory");
#endif
	lcd_reset_high_at = zl_counter();
	lcd_started = 1;
	return 0;
}

/* Direct callers retain the complete synchronous sequence, including every minimum delay. */
const char *zl_lcd_type(void)
{
	uint32_t cfg, pull;
	if (!lcd_started && zl_lcd_begin())
		return 0;
	lcd_started = 0;
	if (zl_delay_since(lcd_reset_high_at, 100000))
		return 0;
	cfg = read32(0x0300b090);
	pull = read32(0x0300b0ac);
	write32(0x0300b090, (cfg & ~(0xfu << 24)) | (6u << 24));
	write32(0x0300b0ac, (pull & ~(3u << 12)) | (1u << 12));
#ifndef ZL_HOST_TEST
	__asm__ volatile("dsb sy" ::: "memory");
#endif
	/*
	 * Let the pad settle before sampling (verify-loader.md): the input was just enabled with a fresh pull-up, and
	 * without a wait the read follows the write by well under a microsecond. Vendor U-Boot has a printf call between
	 * the pull-up write (0x4a0263b2) and the read (0x4a0263c2). 1 ms is far above an internal pull-up's RC time.
	 */
	if (zl_delay_us(1000))
		return 0;
	return read32(0x0300b0a0) & (1u << 6) ? "old" : "boe";
}
