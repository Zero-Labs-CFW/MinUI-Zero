/* SPDX-License-Identifier: GPL-2.0+ */
/* Binary-derived A32 SMC recipe, corrected by ../verify-monitor.md D1. */
#include "monitor.h"
#include <string.h>

#ifdef ZL_DIRECT_PATH
#error "Direct monitor path omits PSCI FDT registration; unsupported"
#endif

int zl_prepare_monitor(void *head, size_t head_len, void *stub, size_t stub_len,
                       const struct zero_params *p)
{

	uint32_t code[20] = {
		0xe59f0038, 0xe59f1040, 0xe3a02000, 0xe3a03000, /* box start: FID,FDT,0,0 */
		0xf57ff04f, 0xf57ff06f, 0xe1600070,             /* dsb; isb; smc #0 */
		0xe59f0020, 0xe59f1020, 0xe59f2020, 0xe3a03001, /* reload ALL kernel args */
		0xf57ff04f, 0xf57ff06f, 0xe1600070,
		0xe320f003, 0xeafffffd,                         /* returned kernel SMC */
		0x8000ff14, 0x8000ff04, 0, 0,
	};
	unsigned char *h = head;
	uint32_t zero = 0;
	uint64_t fdt;

	if (!p || !head || !stub || head_len < 0xb8 || stub_len < sizeof(code) ||
	    p->monitor != ZL_MONITOR_ADDR || p->uboot != ZL_STUB_ADDR ||
	    !p->kernel_addr || p->kernel_addr > UINT32_MAX || !p->dtb || p->dtb > UINT32_MAX ||
	    memcmp(h + 4, "monitor\0", 8))
		return -1;
	memcpy(h + 0x14, &zero, 4); /* normal BL33 path, not direct kernel */
	memcpy(h + 0x18, &zero, 4); /* no BL32 */
	memcpy(h + 0x24, p->board_block, sizeof(p->board_block));
	memcpy(h + 0x30, p->dram_words, sizeof(p->dram_words));
	fdt = p->dtb;
	memcpy(h + 0xb0, &fdt, 8); /* monitor reads a u64, not just its low word */
	code[18] = (uint32_t)p->kernel_addr;
	code[19] = (uint32_t)p->dtb;
	memcpy(stub, code, sizeof(code));
	return 0;
}
