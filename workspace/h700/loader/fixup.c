// SPDX-License-Identifier: GPL-2.0+
/*
 * MinUI Zero loader: build the kernel FDT from the package dtb, with the fixups vendor U-Boot 2018.05 used to make.
 *
 * Evidence used here: the package dtb (item "dtb" of dep-plusfast/package.fex, md5 d95a2dad...) against the live tree
 * of the Plus booted through stage 1 (SPL -> vendor monitor -> vendor U-Boot, 2026-11-05): ../live-dt-plus.dts and
 * ../cmdline-plus.txt. test/offline.py checks every node/property against the normalized live tree.
 *
 * Verified fixups (research-fdt-fixups.md and research-review-codex.md):
 *   /chosen bootargs        template + boot.img header cmdline + snum from the SID (zl_fix_chosen)
 *   /chosen initrd          linux,initrd-start/end as u64 + a /memreserve/ for the ramdisk
 *   /memory@40000000 reg    size = dram_mib MiB (package dtb says 512 MiB, live says 1 GiB)
 *   /soc/platform           debug_mode left untouched, as are display and late-device properties
 *   /dram                   vendor's 24-word legacy mapping (not the modern extended layout)
 * PE6 supplies lcd_type; the SPL's AXP2202 snapshot supplies bootreason/charger mode.
 * No logo/display handover is fabricated. GPT/env policy remains specific to the supplied Zero image.
 */
#include <stddef.h>
#include <stdint.h>
#include <limits.h>
#include <string.h>
#include <malloc.h>
#include <libfdt.h>
#include "zl.h"
#include "rtc.h"
#include "memory_layout.h"
#include "obj/build_id.h"

static int zl_fix_health(void *fdt, const struct zero_params *p, const char *panel)
{
	static const unsigned char build_id[32] = ZL_BUILD_ID_BYTES;
	unsigned char record[64] = {'Z', 'H', 'L', '1'};
	unsigned int profile = (p->flags & ZP_PROFILE_MASK) >> ZP_PROFILE_SHIFT;
	int off = fdt_path_offset(fdt, "/soc@03000000/lcd0@01c0c000"), len;
	const fdt32_t *x, *y;
	unsigned int fields[7];
	if (profile != 1 && profile != 2)
		return -FDT_ERR_BADVALUE;
	if (off < 0 || !panel || (strcmp(panel, "old") && strcmp(panel, "boe")))
		return -FDT_ERR_BADVALUE;
	x = fdt_getprop(fdt, off, "lcd_x", &len);
	if (!x || len != 4 || fdt32_to_cpu(*x) != 640)
		return -FDT_ERR_BADVALUE;
	y = fdt_getprop(fdt, off, "lcd_y", &len);
	if (!y || len != 4 || fdt32_to_cpu(*y) != 480)
		return -FDT_ERR_BADVALUE;
	fields[0] = 1; fields[1] = sizeof(record); fields[2] = profile;
	fields[3] = !strcmp(panel, "boe"); fields[4] = 640; fields[5] = 480; fields[6] = 0;
	for (unsigned int i = 0; i < 7; i++) {
		fdt32_t value = cpu_to_fdt32(fields[i]);
		memcpy(record + 4 + i * 4, &value, 4);
	}
	memcpy(record + 32, build_id, 32);
	off = fdt_path_offset(fdt, "/chosen");
	if (off < 0)
		return off;
	return fdt_setprop(fdt, off, "zero,loader", record, sizeof(record));
}

/*
 * Bootargs, exactly the live Plus cmdline (cmdline-plus.txt) in vendor U-Boot's order: its env "setargs_mmc"
 * (env-plus.bin) with partitions/snum filled in, then the fields vendor U-Boot appends, then the boot.img header
 * cmdline. "disp_reserve=1228800,0x7bf23800" is left out on purpose: it reserves the boot logo's framebuffer and the
 * loader draws no logo (loader-plan.md, 2026-11-05 PLAN).
 * TODO(fixup list): partitions= is what vendor U-Boot read from this card's GPT (names in p1..p6 order); confirm it
 * holds for every Zero card layout (the H's 64 GB card included) or have the SPL pass the GPT names.
 * TODO(fixup list): uboot_message names a U-Boot that no longer runs; kept byte-for-byte until the list says whether
 * anything reads it (the kernel image strings do not contain it; userspace unverified).
 */
#define ZL_ARGS_A	"earlyprintk=sunxi-uart,0x05000000 initcall_debug=0 console=ttyS0,115200 loglevel=4 " \
			"root=/dev/mmcblk0p5 rootwait quiet splash init=/init " \
			"partitions=spare@mmcblk0p1:boot-resource@mmcblk0p2:env@mmcblk0p3:boot@mmcblk0p4:" \
			"rootfs@mmcblk0p5:roms@mmcblk0p6 cma=64M snum="
#define ZL_ARGS_B	" mac_addr= wifi_mac= bt_mac= selinux=0 specialstr= gpt=1 androidboot.mode="
#define ZL_ARGS_C	" androidboot.hardware=sun50iw9p1 boot_type=1 androidboot.boot_type=1 " \
			"androidboot.secure_os_exist=0 gpt=1 uboot_message=2018.05(12/25/2025-11:26:53)"

/* Only the AXP2202 Plus path is qualified by the supplied package/live evidence. */
#ifdef ZL_APPLY_DTBO
#error "AXP1530 overlay probing is not implemented; this experiment is Plus/AXP2202 only"
#endif

/*
 * The kernel copies at most COMMAND_LINE_SIZE - 1 bytes of bootargs and drops the rest silently (2048 on arm64 Linux
 * 4.9, arch/arm64/include/uapi/asm/setup.h: from memory, unverified here). Refuse rather than lose the header cmdline.
 */
#define ZL_ARGS_MAX	2048

/* boot.img v0..v2 header: cmdline[512] at 0x40, extra_cmdline[1024] at 0x260 (bootimg-hdr-plus.bin) */
#define ZL_BOOTIMG_MAGIC	"ANDROID!"
#define ZL_BOOTIMG_VERSION	0x28
#define ZL_BOOTIMG_CMDLINE	0x40
#define ZL_BOOTIMG_CMDLINE_LEN	512
#define ZL_BOOTIMG_EXTRA	0x260
#define ZL_BOOTIMG_EXTRA_LEN	1024

struct zl_str {
	char *buf;
	size_t len, max;
	int err;
};

static void zl_put(struct zl_str *s, const char *p, size_t n)
{
	if (s->err || n >= s->max - s->len) {
		s->err = 1;
		return;
	}
	memcpy(s->buf + s->len, p, n);
	s->len += n;
	s->buf[s->len] = 0;
}

static void zl_puts(struct zl_str *s, const char *p)
{
	zl_put(s, p, strlen(p));
}

/* Fixed-width lowercase hex, matching vendor U-Boot's "%03x%08x%08x". */
static size_t zl_hex(char *out, uint32_t v, size_t width)
{
	for (size_t i = 0; i < width; i++)
		out[i] = "0123456789abcdef"[(v >> (4 * (width - i - 1))) & 0xf];
	return width;
}

/*
 * U-Boot 0x4a00500c: "%03x%08x%08x", SID[1] >> 20, SID[2], SID[3].
 * The old variable-width guess happened to match the Plus but failed other SIDs.
 * Evidence (2026-11-04-boot-speed/loader/uboot-plus.bin): literal pool 0x4a005040..0x4a00504c = 0x03006200..0x0300620c,
 * "lsrs r2, r5, #0x14" at 0x4a005030 on the word from 0x03006204, format string at 0x4a084fd0 = "%03x%08x%08x".
 * Worked on the Plus (SID 33806c00 6c004808 01071654 4c921c12): 0x6c004808 >> 20 = 0x6c0 -> "6c0", then "01071654",
 * then "4c921c12": "6c0" "01071654" "4c921c12" = 6c0010716544c921c12, the snum in ../cmdline-plus.txt.
 */
int zl_snum(char *out, size_t max, const uint32_t sid[4])
{
	char tmp[3 * 8 + 1];
	size_t n;

	n = zl_hex(tmp, sid[1] >> 20, 3);
	n += zl_hex(tmp + n, sid[2], 8);
	n += zl_hex(tmp + n, sid[3], 8);
	if (!out || n >= max)
		return -1;
	memcpy(out, tmp, n);
	out[n] = 0;
	return (int)n;
}

static char zl_args[ZL_ARGS_MAX];

const char *zl_boot_reason(uint32_t regs)
{
	switch (regs & 0xff) {
	case 1: return "button";
	case 2: return "irq";
	case 4: return regs & (1u << 11) ? "charger" : "usb";
	case 8: return "charger";
	case 16: return "battery";
	default: return regs & (1u << 19) ? "charger" : "unknow";
	}
}

static int zl_bootargs(const void *fdt, const struct zero_params *p, const char **selected_panel)
{
	const char *hdr = (const char *)(uintptr_t)p->bootimg_hdr;
	struct zl_str s = { zl_args, 0, sizeof(zl_args), 0 };
	char snum[32];
	uint32_t sid[4], ver;
	size_t n;
	const char *reason = zl_boot_reason(p->pmic_boot_regs);
	const char *lcd;
	const fdt32_t *battery;
	int off, len, charger = !strcmp(reason, "charger");

	if (!hdr || memcmp(hdr, ZL_BOOTIMG_MAGIC, 8))
		return -FDT_ERR_BADVALUE;
	memcpy(&ver, hdr + ZL_BOOTIMG_VERSION, 4);
	if (ver > 2)	/* v3+ moved the cmdline */
		return -FDT_ERR_BADVALUE;
	zl_sid_read(sid);
	if (zl_snum(snum, sizeof(snum), sid) < 0)
		return -FDT_ERR_INTERNAL;
	zl_args[0] = 0;
	zl_puts(&s, ZL_ARGS_A);
	zl_puts(&s, snum);
	zl_puts(&s, ZL_ARGS_B);
	off = fdt_path_offset(fdt, "/soc/power_sply");
	battery = off < 0 ? NULL : fdt_getprop(fdt, off, "battery_exist", &len);
	if (battery && len != 4)
		return -FDT_ERR_BADVALUE;
	if (battery && fdt32_to_cpu(*battery) == 0)
		charger = 0;
	zl_puts(&s, charger ? "charger" : "normal");
	zl_puts(&s, " androidboot.serialno=");
	zl_puts(&s, snum);
	zl_puts(&s, ZL_ARGS_C);
	zl_puts(&s, " bootreason=");
	zl_puts(&s, reason);
	zl_puts(&s, " lcd_type=");
	lcd = zl_lcd_type_rule(zl_panel_rule_for_profile((p->flags & ZP_PROFILE_MASK) >> ZP_PROFILE_SHIFT));
	*selected_panel = lcd;
	if (!lcd)
		return -FDT_ERR_BADVALUE;
	zl_puts(&s, lcd);
	n = strnlen(hdr + ZL_BOOTIMG_CMDLINE, ZL_BOOTIMG_CMDLINE_LEN);
	if (n == ZL_BOOTIMG_CMDLINE_LEN)
		return -FDT_ERR_BADVALUE;
	if (n) {
		zl_puts(&s, " ");
		zl_put(&s, hdr + ZL_BOOTIMG_CMDLINE, n);
	}
	/* Vendor 0x4a012468 appends only cmdline[512]. Reject unqualified extra_cmdline. */
	if (hdr[ZL_BOOTIMG_EXTRA])
		return -FDT_ERR_BADVALUE;
	return s.err ? -FDT_ERR_NOSPACE : 0;
}

static int zl_fix_chosen(void *fdt, const struct zero_params *p, const char **selected_panel)
{
	int off, r;

	r = zl_bootargs(fdt, p, selected_panel);
	if (r)
		return r;
	off = fdt_path_offset(fdt, "/chosen");
	if (off == -FDT_ERR_NOTFOUND)
		off = fdt_add_subnode(fdt, 0, "chosen");
	if (off < 0)
		return off;
	r = fdt_setprop_string(fdt, off, "bootargs", zl_args);
	if (r)
		return r;
	if (!p->ramdisk_len) {
		r = fdt_delprop(fdt, off, "linux,initrd-start");
		if (r && r != -FDT_ERR_NOTFOUND)
			return r;
		r = fdt_delprop(fdt, off, "linux,initrd-end");
		return r == -FDT_ERR_NOTFOUND ? 0 : r;
	}
	if (p->ramdisk_len > UINT64_MAX - p->ramdisk)
		return -FDT_ERR_BADVALUE;
	/* as the live tree: <0x00 0x42000000> / <0x00 0x42000200>, and a /memreserve/ like vendor U-Boot's fdt_initrd */
	r = fdt_setprop_u64(fdt, off, "linux,initrd-start", p->ramdisk);
	if (!r)
		r = fdt_setprop_u64(fdt, off, "linux,initrd-end", p->ramdisk + p->ramdisk_len);
	if (!r)
		r = fdt_add_mem_rsv(fdt, p->ramdisk, p->ramdisk_len);
	return r;
}

/* reg = <base size> in the root's #address-cells/#size-cells (2/2 in the package dtb) */
static int zl_fix_memory(void *fdt, const struct zero_params *p)
{
	uint64_t base = ZL_DRAM_BASE, size = zl_physical_dram_size(p->dram_mib);
	fdt32_t reg[4];
	int ac, sc, n = 0, off, r;

	if (!size)
		return -FDT_ERR_BADVALUE;
	ac = fdt_address_cells(fdt, 0);
	sc = fdt_size_cells(fdt, 0);
	if (ac < 1 || ac > 2 || sc < 1 || sc > 2 || (sc == 1 && size > UINT32_MAX))
		return -FDT_ERR_BADNCELLS;
	if (ac == 2)
		reg[n++] = cpu_to_fdt32(base >> 32);
	reg[n++] = cpu_to_fdt32((uint32_t)base);
	if (sc == 2)
		reg[n++] = cpu_to_fdt32(size >> 32);
	reg[n++] = cpu_to_fdt32((uint32_t)size);
	off = fdt_path_offset(fdt, "/memory@40000000");
	if (off == -FDT_ERR_NOTFOUND)
		off = fdt_path_offset(fdt, "/memory");
	if (off == -FDT_ERR_NOTFOUND) {
		off = fdt_add_subnode(fdt, 0, "memory@40000000");
		if (off >= 0) {
			r = fdt_setprop_string(fdt, off, "device_type", "memory");
			if (r)
				return r;
		}
	}
	if (off < 0)
		return off;
	return fdt_setprop(fdt, off, "reg", reg, n * sizeof(reg[0]));
}

/*
 * Vendor U-Boot 0x4a003068 rewrites these 24 properties from head+0x30..+0x8c. The
 * values the live trees show (stock: 2026-11-04-boot-speed/loader/live-fdt-plus.dts /dram against
 * stock-uboot-head-plus.bin +0x30..+0x8c; stage 1: ../live-dt-plus.dts:6595-6638, where dram_tpr13 = 0x80000000 is
 * the SPL's own no-write-back bit on U-Boot head word 23, zero_vendor.c, and stock shows 0). The other /dram
 * properties (dx_odt, dx_dri, ca_dri, mr4..mr22) are equal in the package dtb and the live tree, so they stay.
 * Export bit31 of legacy word23 for stage-1 FDT parity. It is writeback policy,
 * not a training result. The monitor/resume array keeps all physical words raw.
 */
static const char *const zl_dram_names[24] = {
	"dram_clk", "dram_type", "dram_zq", "dram_odt_en", "dram_para1", "dram_para2",
	"dram_mr0", "dram_mr1", "dram_mr2", "dram_mr3",
	"dram_tpr0", "dram_tpr1", "dram_tpr2", "dram_tpr3", "dram_tpr4", "dram_tpr5", "dram_tpr6",
	"dram_tpr7", "dram_tpr8", "dram_tpr9", "dram_tpr10", "dram_tpr11", "dram_tpr12", "dram_tpr13",
};

static int zl_fix_dram(void *fdt, const struct zero_params *p)
{
	int off = fdt_path_offset(fdt, "/dram"), i, r;

	if (off < 0)
		return off;
	for (i = 0; i < 24; i++) {
		/* FDT export parity only; never alter the monitor's physical DRAM words. */
		r = fdt_setprop_u32(fdt, off, zl_dram_names[i], p->dram_words[i] | (i == 23 ? 0x80000000u : 0));
		if (r)
			return r;
	}
	return 0;
}

/* The SPL's conservative battery guard covers this policy only. Do not silently accept a different package. */
static int zl_battery_policy(const void *fdt)
{
	const fdt32_t *v;
	int off = fdt_path_offset(fdt, "/soc/charger0"), len;

	if (off < 0)
		return off;
	v = fdt_getprop(fdt, off, "pmu_safe_vol", &len);
	if (!v || len != 4 || fdt32_to_cpu(*v) != 3450)
		return -FDT_ERR_BADVALUE;
	v = fdt_getprop(fdt, off, "pmu_safe_ratio", &len);
	if (v && (len != 4 || fdt32_to_cpu(*v) != 1))
		return -FDT_ERR_BADVALUE;
	off = fdt_path_offset(fdt, "/soc/power_sply");
	if (off < 0)
		return off;
	v = fdt_getprop(fdt, off, "ntc_status", &len);
	if (v && (len != 4 || fdt32_to_cpu(*v) != 0))
		return -FDT_ERR_BADVALUE;
	return 0;
}

int zl_fixup_fdt(void *fdt, const struct zero_params *p)
{
	int r;
	const char *panel = 0;

	if (!fdt || !p)
		return -FDT_ERR_BADVALUE;
	r = zl_battery_policy(fdt);
	if (!r)
		r = zl_fix_chosen(fdt, p, &panel);
	if (!r)
		r = zl_fix_memory(fdt, p);
	if (!r)
		r = zl_fix_dram(fdt, p);
	if (!r)
		r = zl_fix_health(fdt, p, panel);
	return r;
}

/*
 * The package dtb, checked, opened in place with room to grow (fdt_max), the optional overlay, the fixups, packed.
 * Returns 0 or a negative libfdt error.
 */
int zl_build_fdt(const struct zero_params *p)
{
	void *fdt;
	int r;

	if (!p || !p->dtb || p->dtb_len < sizeof(struct fdt_header) || p->dtb_len > INT_MAX || p->fdt_max > ZL_FDT_MAX ||
	    p->fdt_max < p->dtb_len)
		return -FDT_ERR_BADVALUE;
	fdt = (void *)(uintptr_t)p->dtb;
	r = fdt_check_full(fdt, p->dtb_len);	/* header, totalsize <= what was read, the whole structure */
	if (r)
		return r;
	/* Never infer the monitor reservation from /proc/device-tree: fs extraction loses it. */
	{
		uint64_t addr, size;
		int found = 0;
		for (int i = 0; i < fdt_num_mem_rsv(fdt); i++) {
			if (fdt_get_mem_rsv(fdt, i, &addr, &size))
				return -FDT_ERR_BADVALUE;
			if (addr == p->monitor && size == 0x1000000)
				found = 1;
		}
		if (!found)
			return -FDT_ERR_BADVALUE;
	}
	r = fdt_open_into(fdt, fdt, (int)p->fdt_max);
	if (r)
		return r;
#ifdef ZL_APPLY_DTBO
	/*
	 * Off by default: vendor U-Boot did not apply the package dtbo on the Plus (its axp1530 PMU node on twi5 is absent
	 * from ../live-dt-plus.dts). fdt_overlay_apply consumes the overlay, so it works on a copy.
	 */
	if (p->dtbo_len) {
		void *o;

		if (p->dtbo_len > INT_MAX)
			return -FDT_ERR_BADVALUE;
		o = malloc(p->dtbo_len);
		if (!o)
			return -FDT_ERR_NOSPACE;
		memcpy(o, (const void *)(uintptr_t)p->dtbo, p->dtbo_len);
		r = fdt_check_full(o, p->dtbo_len);
		if (!r)
			r = fdt_overlay_apply(fdt, o);
		if (r)
			return r;
	}
#endif
	r = zl_fixup_fdt(fdt, p);
	if (r)
		return r;
	return fdt_pack(fdt);
}
