#include "offline_util.h"
#include "offline_soc.h"
#include "zl.h"
#include "rtc.h"
#include <libfdt.h>

static const char *const dram_names[] = {
	"dram_clk", "dram_type", "dram_zq", "dram_odt_en", "dram_para1", "dram_para2", "dram_mr0", "dram_mr1",
	"dram_mr2", "dram_mr3", "dram_tpr0", "dram_tpr1", "dram_tpr2", "dram_tpr3", "dram_tpr4", "dram_tpr5",
	"dram_tpr6", "dram_tpr7", "dram_tpr8", "dram_tpr9", "dram_tpr10", "dram_tpr11", "dram_tpr12", "dram_tpr13",
};
static const char *args(void *fdt)
{
	const char *v = fdt_getprop(fdt, fdt_path_offset(fdt, "/chosen"), "bootargs", NULL);
	CHECK(v != NULL);
	return v;
}
static void fresh(void *dst, const void *src, size_t len) { memset(dst, 0xa5, ZL_FDT_MAX + 16); memcpy(dst, src, len); }
int main(int argc, char **argv)
{
	size_t pkg_len, hdr_len, pin_len, overlay_len;
	unsigned char *pkg, *hdr, *pin, *overlay, *fdt;
	struct zero_params p = {0}, good;
	char serial[32];
	uint32_t sid[4] = {0};
	CHECK(argc == 6);
	pkg = read_file(argv[1], &pkg_len); hdr = read_file(argv[2], &hdr_len);
	pin = read_file(argv[3], &pin_len); overlay = read_file(argv[4], &overlay_len);
	CHECK(hdr_len == 2048 && pin_len >= 0xf8);
	fdt = malloc(ZL_FDT_MAX + 16); CHECK(fdt != NULL);
	p.dtb = (uintptr_t)fdt; p.dtb_len = pkg_len; p.fdt_max = ZL_FDT_MAX;
	p.dtbo = (uintptr_t)overlay; p.dtbo_len = overlay_len;
	p.monitor = 0x48000000; p.bootimg_hdr = (uintptr_t)hdr;
	p.ramdisk = 0x42000000; p.ramdisk_len = 512; p.dram_mib = 1024; p.pmic_boot_regs = 1;
	p.flags = ZP_FLAG_CARD | ZP_PROFILE_PLUS;
	memcpy(p.dram_words, pin + 0x38, sizeof(p.dram_words));
	good = p;
	mock_reset(); fresh(fdt, pkg, pkg_len);
	CHECK(zl_build_fdt(&p) == 0 && fdt_check_full(fdt, ZL_FDT_MAX) == 0);
	for (size_t i = 0; i < 16; i++) CHECK(fdt[ZL_FDT_MAX + i] == 0xa5);
	int off = fdt_path_offset(fdt, "/dram"), len;
	for (size_t i = 0; i < 24; i++) {
		const fdt32_t *v = fdt_getprop(fdt, off, dram_names[i], &len);
		CHECK(v && len == 4 && fdt32_to_cpu(*v) == (p.dram_words[i] | (i == 23 ? 0x80000000u : 0)));
	}
	CHECK(strstr(args(fdt), "snum=6c0010716544c921c12 ") != NULL);
	CHECK(strstr(args(fdt), "disp_reserve=") == NULL);
	CHECK(fdt_num_mem_rsv(fdt) == 2);
	const unsigned char *health = fdt_getprop(fdt, fdt_path_offset(fdt, "/chosen"), "zero,loader", &len);
	CHECK(health && len == 64 && !memcmp(health, "ZHL1", 4));
	CHECK(fdt32_to_cpu(*(const fdt32_t *)(health + 12)) == 1);
	write_file(argv[5], fdt, fdt_totalsize(fdt));
	CHECK(zl_snum(serial, sizeof(serial), sid) == 19 && !strcmp(serial, "0000000000000000000"));
	sid[1] = 0x12300000; sid[2] = 1; sid[3] = 2;
	CHECK(zl_snum(serial, sizeof(serial), sid) == 19 && !strcmp(serial, "1230000000100000002"));
	CHECK(zl_snum(serial, 19, sid) < 0);
	struct { uint32_t regs; const char *reason, *mode; } cases[] = {
		{1,"button","normal"}, {2,"irq","normal"}, {4,"usb","normal"}, {0x804,"charger","charger"},
		{8,"charger","charger"}, {16,"battery","normal"}, {0,"unknow","normal"},
		{0x080000,"charger","charger"}, {3,"unknow","normal"}, {0x080003,"charger","charger"},
	};
	for (size_t i = 0; i < sizeof(cases)/sizeof(cases[0]); i++) {
		char token[64]; p = good; p.pmic_boot_regs = cases[i].regs; fresh(fdt, pkg, pkg_len);
		CHECK(!strcmp(zl_boot_reason(p.pmic_boot_regs), cases[i].reason));
		CHECK(zl_build_fdt(&p) == 0);
		snprintf(token, sizeof(token), "bootreason=%s ", cases[i].reason); CHECK(strstr(args(fdt), token));
		snprintf(token, sizeof(token), "androidboot.mode=%s ", cases[i].mode); CHECK(strstr(args(fdt), token));
	}
	p = good; p.pmic_boot_regs = 8; fresh(fdt, pkg, pkg_len);
	CHECK(fdt_open_into(fdt, fdt, ZL_FDT_MAX) == 0);
	CHECK(fdt_setprop_u32(fdt, fdt_path_offset(fdt, "/soc/power_sply"), "battery_exist", 0) == 0);
	CHECK(fdt_pack(fdt) == 0);
	p.dtb_len = fdt_totalsize(fdt);
	CHECK(zl_build_fdt(&p) == 0 && strstr(args(fdt), "androidboot.mode=normal "));
	p = good; fresh(fdt, pkg, pkg_len); mock_set(0x0300b0a0, 0);
	CHECK(zl_build_fdt(&p) == 0 && strstr(args(fdt), "lcd_type=boe "));
	health = fdt_getprop(fdt, fdt_path_offset(fdt, "/chosen"), "zero,loader", &len);
	CHECK(health && len == 64 && fdt32_to_cpu(*(const fdt32_t *)(health + 16)) == 1);
	/* Unknown profiles and unqualified dimensions must never get a healthy record. */
	for (unsigned profile = 0; profile < 4; ++profile) {
		p = good; p.flags = ZP_FLAG_CARD | (profile << 8); fresh(fdt, pkg, pkg_len);
		mock_reset();
		CHECK((zl_build_fdt(&p) == 0) == (profile == 1 || profile == 2));
	}
	p = good; fresh(fdt, pkg, pkg_len); CHECK(fdt_open_into(fdt, fdt, ZL_FDT_MAX) == 0);
	CHECK(fdt_setprop_u32(fdt, fdt_path_offset(fdt, "/soc@03000000/lcd0@01c0c000"), "lcd_x", 720) == 0);
	CHECK(fdt_pack(fdt) == 0); p.dtb_len = fdt_totalsize(fdt);
	CHECK(zl_build_fdt(&p) < 0);
	mock_reset(); p = good; p.ramdisk_len = 0; fresh(fdt, pkg, pkg_len);
	CHECK(zl_build_fdt(&p) == 0);
	off = fdt_path_offset(fdt, "/chosen");
	CHECK(!fdt_getprop(fdt, off, "linux,initrd-start", NULL));
	CHECK(!fdt_getprop(fdt, off, "linux,initrd-end", NULL));
	CHECK(fdt_num_mem_rsv(fdt) == 1);
	/* Structural growth must not reuse a stale node offset. */
	p = good; fresh(fdt, pkg, pkg_len); CHECK(fdt_open_into(fdt, fdt, ZL_FDT_MAX) == 0);
	CHECK(fdt_del_node(fdt, fdt_path_offset(fdt, "/chosen")) == 0);
	CHECK(fdt_del_node(fdt, fdt_path_offset(fdt, "/memory@40000000")) == 0);
	CHECK(fdt_pack(fdt) == 0);
	CHECK(zl_build_fdt(&p) == 0 && fdt_path_offset(fdt, "/memory@40000000") > 0);
	CHECK(strstr(args(fdt), "root=/dev/mmcblk0p5 "));
	/* A different battery policy is not qualified by the SPL's fixed Plus guard. */
	struct { const char *path, *prop; uint32_t value; int ok; } policies[] = {
		{"/soc/charger0","pmu_safe_vol",3450,1},
		{"/soc/charger0","pmu_safe_vol",3500,0},
		{"/soc/charger0","pmu_safe_ratio",1,1},
		{"/soc/charger0","pmu_safe_ratio",2,0},
		{"/soc/power_sply","ntc_status",0,1},
		{"/soc/power_sply","ntc_status",1,0},
	};
	for(size_t i=0;i<sizeof(policies)/sizeof(policies[0]);i++) {
		p=good;fresh(fdt,pkg,pkg_len);CHECK(fdt_open_into(fdt,fdt,ZL_FDT_MAX)==0);
		CHECK(fdt_setprop_u32(fdt,fdt_path_offset(fdt,policies[i].path),policies[i].prop,policies[i].value)==0);
		CHECK(fdt_pack(fdt)==0);p.dtb_len=fdt_totalsize(fdt);
		CHECK((zl_build_fdt(&p)==0)==policies[i].ok);
	}
	p=good;fresh(fdt,pkg,pkg_len);CHECK(fdt_open_into(fdt,fdt,ZL_FDT_MAX)==0);
	CHECK(fdt_delprop(fdt,fdt_path_offset(fdt,"/soc/charger0"),"pmu_safe_vol")==0);
	CHECK(fdt_pack(fdt)==0);p.dtb_len=fdt_totalsize(fdt);CHECK(zl_build_fdt(&p)<0);
	p=good;fresh(fdt,pkg,pkg_len);CHECK(fdt_open_into(fdt,fdt,ZL_FDT_MAX)==0);
	CHECK(fdt_setprop(fdt,fdt_path_offset(fdt,"/soc/charger0"),"pmu_safe_vol","x",2)==0);
	CHECK(fdt_pack(fdt)==0);p.dtb_len=fdt_totalsize(fdt);CHECK(zl_build_fdt(&p)<0);
	/* Malformed input, missing monitor reserve, short item and insufficient slack. */
	p = good; fresh(fdt, pkg, pkg_len); fdt[0] ^= 1; CHECK(zl_build_fdt(&p) < 0);
	p = good; fresh(fdt, pkg, pkg_len); p.dtb_len = 39; CHECK(zl_build_fdt(&p) < 0);
	p = good; fresh(fdt, pkg, pkg_len); p.dtb_len = fdt_totalsize(fdt) - 1; CHECK(zl_build_fdt(&p) < 0);
	p = good; fresh(fdt, pkg, pkg_len); p.fdt_max = pkg_len; CHECK(zl_build_fdt(&p) < 0);
	p = good; fresh(fdt, pkg, pkg_len); CHECK(fdt_del_mem_rsv(fdt, 0) == 0); CHECK(zl_build_fdt(&p) < 0);
	p = good; fresh(fdt, pkg, pkg_len); hdr[0] ^= 1; CHECK(zl_build_fdt(&p) < 0); hdr[0] ^= 1;
	p = good; fresh(fdt, pkg, pkg_len); hdr[0x260] = 'x'; CHECK(zl_build_fdt(&p) < 0); hdr[0x260] = 0;
	CHECK(zl_build_fdt(NULL) < 0);
	free(fdt); free(pkg); free(hdr); free(pin); free(overlay);
	printf("PASS FDT/PMIC/SID: %u checks; actual DTB written for exhaustive live-tree comparison\n", checks);
	return 0;
}
