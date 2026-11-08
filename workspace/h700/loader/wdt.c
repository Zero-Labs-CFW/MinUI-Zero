// SPDX-License-Identifier: GPL-2.0+
/*
 * MinUI Zero loader: the sunxi watchdog (WDOG0 of the H616 timer block).
 *
 * Base 0x030090a0: SUNXI_TIMER_BASE 0x03009000 (asm/arch-sunxi/cpu_sun50i_h6.h:15) + 0xa0 (struct sunxi_timer_reg,
 * asm/arch-sunxi/timer.h:62-83: wdog[0] after the 6 timers, AVS and 16 reserved bytes). Registers (struct sunxi_wdog,
 * asm/arch-sunxi/watchdog.h:36-44): ctl +0x10, cfg +0x14, mode +0x18. ctl key 0xa57 << 1 with restart bit 0 = 0x14af
 * (watchdog.h:12-13), cfg 1 = reset the whole system, mode = interval << 4 | enable. Intervals as zero_vendor.c
 * zv_wdog_arm (0 = 0.5 s, 7 = 8 s) and U-Boot's drivers/watchdog/sunxi_wdt.c wdt_timeout_map (0xb = 16 s); the
 * same register writes as the test kit's h-ramoops/gp-mark.sh:16-18 (cfg 1, mode 0xb1, ctl 0x14af).
 */
#include "rtc.h"
#include "zl.h"

#define ZL_WDT_BASE	0x030090a0UL
#define ZL_WDT_CTL	(ZL_WDT_BASE + 0x10)
#define ZL_WDT_CFG	(ZL_WDT_BASE + 0x14)
#define ZL_WDT_MODE	(ZL_WDT_BASE + 0x18)
#define ZL_WDT_KICK	((0xa57u << 1) | 1u)	/* 0x14af: key | restart */
#define ZL_WDT_CFG_SYS	1u			/* reset the whole system */
#define ZL_WDT_EN	1u
#define ZL_WDT_0S5	0x0			/* interval codes */
#define ZL_WDT_16S	0xb

/* the test kit's try budget (h-ramoops/gp-mark.sh:11-15, set by h-try.sh): GP5 = 0x5d000000 | tries left */
#define ZL_GP5_TAG	0x5d000000u

static void zl_wdog_arm(uint32_t intv)
{
	write32(ZL_WDT_CFG, ZL_WDT_CFG_SYS);
	write32(ZL_WDT_MODE, (intv << 4) | ZL_WDT_EN);
	write32(ZL_WDT_CTL, ZL_WDT_KICK);
}

/*
 * Just before the hand-off. A test try is pending (GP5 budget 1..15): keep the watchdog armed for 16 s and kick it, so
 * a monitor or kernel hang still resets into the SPL safety net (gp-mark.sh re-arms it from userspace). Otherwise
 * disarm: the vendor chain does not expect a running watchdog (zero_vendor.c, the write before its hand-off).
 */
void zl_wdog_policy(void)
{
	uint32_t budget = read32(ZL_RTC_GP5) ^ ZL_GP5_TAG;

	if (budget >= 1 && budget <= 15)
		zl_wdog_arm(ZL_WDT_16S);
	else
		write32(ZL_WDT_MODE, 0);
}

/* failure: reset in 0.5 s; the SPL then finds GP15 still set and restores the stock boot0 (zero_vendor_early) */
void zl_reset_now(void)
{
	zl_wdog_arm(ZL_WDT_0S5);
	for (;;)
		__asm__ volatile("" ::: "memory");
}
