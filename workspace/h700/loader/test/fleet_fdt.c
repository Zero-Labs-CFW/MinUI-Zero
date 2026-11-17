/* SPDX-License-Identifier: GPL-2.0+ */
#include "offline_util.h"
#include "offline_soc.h"
#include "zl.h"
#include "display_contract.h"
#include "obj/build_id.h"
#include <libfdt.h>

static unsigned number(const char *text)
{
	char *end;
	unsigned long value = strtoul(text, &end, 10);
	CHECK(*text && !*end && value <= 0xfffffffful);
	return (unsigned)value;
}

int main(int argc, char **argv)
{
	size_t dtb_len, hdr_len, overlay_len, dram_len;
	unsigned char *dtb, *header, *overlay, *dram, *output;
	struct zero_params params = {0};
	struct zero_display_contract display;
	static const unsigned char build_id[32] = ZL_BUILD_ID_BYTES;
	const fdt32_t *reg;
	const unsigned char *record;
	int length;
	CHECK(argc == 9);
	dtb = read_file(argv[1], &dtb_len);
	header = read_file(argv[2], &hdr_len);
	overlay = read_file(argv[3], &overlay_len);
	dram = read_file(argv[4], &dram_len);
	CHECK(hdr_len == 2048 && dram_len == sizeof(params.dram_words));
	unsigned profile = number(argv[5]), mib = number(argv[6]), strap = number(argv[7]);
	CHECK(profile > 0 && profile <= 255 && strap <= 1);
	CHECK(zero_display_profile(profile, &display) && zero_display_v1_compatible(&display));
	CHECK(dtb_len <= ZL_FDT_MAX);
	output = malloc(ZL_FDT_MAX + 16);
	CHECK(output != NULL);
	memset(output, 0xa5, ZL_FDT_MAX + 16);
	memcpy(output, dtb, dtb_len);
	params.magic = ZP_MAGIC; params.version = ZP_VERSION; params.size = sizeof(params);
	params.flags = ZP_FLAG_CARD | (profile << ZP_PROFILE_SHIFT);
	params.dtb = (uintptr_t)output; params.dtb_len = dtb_len; params.fdt_max = ZL_FDT_MAX;
	params.dtbo = (uintptr_t)overlay; params.dtbo_len = overlay_len;
	params.bootimg_hdr = (uintptr_t)header; params.monitor = 0x48000000;
	params.ramdisk = 0x42000000; params.ramdisk_len = header[16] | ((unsigned)header[17] << 8) |
		((unsigned)header[18] << 16) | ((unsigned)header[19] << 24);
	params.dram_mib = mib; params.pmic_boot_regs = 1;
	for (unsigned i = 0; i < 32; i++)
		params.dram_words[i] = dram[i * 4] | ((unsigned)dram[i * 4 + 1] << 8) |
			((unsigned)dram[i * 4 + 2] << 16) | ((unsigned)dram[i * 4 + 3] << 24);
	CHECK(zero_profile_memory(profile, mib, params.dram_words[1]));
	/* Register values/SID come from the existing host stub, never from a unit. */
	mock_reset();
	mock_set(0x0300b0a0, strap << 6);
	struct zero_params before = params;
	CHECK(zl_build_fdt(&params) == 0);
	CHECK(!memcmp(&before, &params, sizeof(params)));
	CHECK(fdt_check_full(output, ZL_FDT_MAX) == 0);
	for (unsigned i = 0; i < 16; i++) CHECK(output[ZL_FDT_MAX + i] == 0xa5);
	record = fdt_getprop(output, fdt_path_offset(output, "/chosen"), "zero,loader", &length);
	CHECK(record && length == 64 && !memcmp(record, "ZHL1", 4));
	fdt32_t fields[7];
	memcpy(fields, record + 4, sizeof(fields));
	CHECK(fdt32_to_cpu(fields[0]) == 1 && fdt32_to_cpu(fields[1]) == 64);
	CHECK(fdt32_to_cpu(fields[2]) == profile && fdt32_to_cpu(fields[3]) <= 1);
	CHECK(fdt32_to_cpu(fields[4]) == display.lcd_width && fdt32_to_cpu(fields[5]) == display.lcd_height);
	CHECK(fdt32_to_cpu(fields[6]) == 0 && !memcmp(record + 32, build_id, 32));
	reg = fdt_getprop(output, fdt_path_offset(output, "/memory@40000000"), "reg", &length);
	CHECK(reg && length == 16);
	CHECK(fdt32_to_cpu(reg[0]) == 0 && fdt32_to_cpu(reg[1]) == 0x40000000);
	CHECK(fdt32_to_cpu(reg[2]) == 0 && fdt32_to_cpu(reg[3]) == ((uint64_t)mib << 20));
	write_file(argv[8], output, fdt_totalsize(output));
	free(output); free(dram); free(overlay); free(header); free(dtb);
	printf("PASS profile %u strap %u: %u production FDT checks (RAM requirement %u, NOT measured)\n",
		profile, strap, checks, mib);
	return 0;
}
