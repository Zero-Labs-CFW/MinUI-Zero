// SPDX-License-Identifier: GPL-2.0+
/*
 * MinUI Zero loader host test: the MMIO that rtc.c reaches under ZL_HOST_TEST (rtc.h). Reads of the SID words return
 * zl_test_sid (the Plus unless a test changes it), the PE data register reports PE6 high ("old" panel), everything
 * else reads 0; writes are dropped.
 */
#include <stdint.h>
#include "rtc.h"

uint32_t zl_test_sid[4] = { 0x33806c00, 0x6c004808, 0x01071654, 0x4c921c12 };	/* the Plus */

void write32(unsigned long addr, uint32_t val)
{
	(void)addr;
	(void)val;
}

uint32_t read32(unsigned long addr)
{
	if (addr >= 0x03006200 && addr < 0x03006210 && !(addr & 3))
		return zl_test_sid[(addr - 0x03006200) / 4];
	if (addr == 0x0300b0a0)
		return 1u << 6;
	return 0;
}

uint64_t zl_test_counter(void)
{
	return 0;
}
