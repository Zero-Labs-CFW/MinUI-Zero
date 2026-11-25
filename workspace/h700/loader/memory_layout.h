/* SPDX-License-Identifier: GPL-2.0+ */
#ifndef ZL_MEMORY_LAYOUT_H
#define ZL_MEMORY_LAYOUT_H

#include <stdint.h>
#include "zl.h"

/* start.S maps only the first GiB. Linux may use more physical RAM after its own MMU setup. */
#define ZL_DRAM_MAPPED_END (ZL_DRAM_BASE + 0x40000000ull)

static inline uint64_t zl_physical_dram_size(uint32_t mib)
{
	if (!mib || (mib > 1024 && mib != 2048))
		return 0;
	return (uint64_t)mib << 20;
}

static inline uint64_t zl_mapped_dram_end(uint32_t mib)
{
	uint64_t size = zl_physical_dram_size(mib);
	if (!size)
		return 0;
	uint64_t end = ZL_DRAM_BASE + size;
	return end < ZL_DRAM_MAPPED_END ? end : ZL_DRAM_MAPPED_END;
}

#endif
