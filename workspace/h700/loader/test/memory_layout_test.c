/* SPDX-License-Identifier: GPL-2.0+ */
#include <assert.h>
#include <stdio.h>
#include "memory_layout.h"

int main(void)
{
	assert(!zl_physical_dram_size(0) && !zl_mapped_dram_end(0));
	for (uint32_t mib = 1; mib <= 1024; mib++) {
		assert(zl_physical_dram_size(mib) == ((uint64_t)mib << 20));
		assert(zl_mapped_dram_end(mib) == ZL_DRAM_BASE + ((uint64_t)mib << 20));
	}
	assert(zl_physical_dram_size(2048) == 0x80000000ull);
	assert(ZL_DRAM_BASE + zl_physical_dram_size(2048) == 0xc0000000ull);
	assert(zl_mapped_dram_end(2048) == 0x80000000ull);
	for (uint32_t mib = 1025; mib < 2048; mib++)
		assert(!zl_physical_dram_size(mib) && !zl_mapped_dram_end(mib));
	assert(!zl_physical_dram_size(2049) && !zl_mapped_dram_end(2049));
	assert(!zl_physical_dram_size(UINT32_MAX) && !zl_mapped_dram_end(UINT32_MAX));
	puts("PASS physical/mapped RAM separation: 1..1024 MiB, exact 2 GiB, invalid gaps/overflow; no board admission");
	return 0;
}
